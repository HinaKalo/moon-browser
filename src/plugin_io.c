#include "win_internal.h"
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

enum { PIPE_CAPACITY = 65536, FRAME_LIMIT = 32768 };
struct MoonPipe {
    HANDLE process, job, input, output;
    uint64_t deadline;
    size_t consumed, buffered;
    char bytes[4096];
};
static void dispose(HANDLE *handle) {
    if (*handle && *handle != INVALID_HANDLE_VALUE) CloseHandle(*handle);
    *handle = NULL;
}
static DWORD WINAPI run_task(void *task) { moon_plugin_worker(task); return 0; }
bool moon_plugin_thread(void *task) {
    HANDLE thread = CreateThread(NULL,0,run_task,task,0,NULL);
    if (!thread) return false;
    CloseHandle(thread);
    return true;
}
void moon_plugin_wait(void) { Sleep(8); }
static DWORD WINAPI run_market(void *unused) { moon_market_worker(); return 0; }
bool moon_market_thread(void) {
    HANDLE thread = CreateThread(NULL,0,run_market,NULL,0,NULL);
    if (!thread) return false;
    CloseHandle(thread);
    return true;
}
void moon_pipe_set_budget(MoonPipe *pipe, unsigned millis) { pipe->deadline = GetTickCount64() + millis; }
MoonPipe *moon_pipe_open(const char *executable, uint32_t *error) {
    *error = ERROR_INVALID_PARAMETER;
    wchar_t path[2048], cwd[2048];
    if (!moon_utf16(executable,path,ARRAYSIZE(path))) return NULL;
    DWORD attributes = GetFileAttributesW(path);
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)))
        return NULL;
    wcscpy(cwd,path);
    wchar_t *slash = wcsrchr(cwd,L'\\');
    if (!slash) return NULL;
    *slash = 0;
    MoonPipe *pipe = calloc(1,sizeof(*pipe));
    if (!pipe) return NULL;
    HANDLE child_in = NULL, child_out = NULL, child_error = NULL;
    SECURITY_ATTRIBUTES inherit = {sizeof(inherit),NULL,TRUE};
    STARTUPINFOEXW startup = {.StartupInfo.cb = sizeof(startup)};
    PROCESS_INFORMATION child = {0};
    SIZE_T bytes = 0;
    bool initialized = false, ok = false;
    if (!CreatePipe(&child_in,&pipe->input,&inherit,PIPE_CAPACITY) ||
        !CreatePipe(&pipe->output,&child_out,&inherit,PIPE_CAPACITY)) goto cleanup;
    SetHandleInformation(pipe->input,HANDLE_FLAG_INHERIT,0);
    SetHandleInformation(pipe->output,HANDLE_FLAG_INHERIT,0);
    child_error = CreateFileW(L"NUL",GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,&inherit,OPEN_EXISTING,0,NULL);
    if (child_error == INVALID_HANDLE_VALUE) goto cleanup;
    HANDLE handles[] = {child_in,child_out,child_error};
    InitializeProcThreadAttributeList(NULL,1,0,&bytes);
    startup.lpAttributeList = malloc(bytes);
    if (!startup.lpAttributeList || !InitializeProcThreadAttributeList(startup.lpAttributeList,1,0,&bytes)) goto cleanup;
    initialized = true;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_HANDLE_LIST,handles,sizeof(handles),NULL,NULL))
        goto cleanup;
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = child_in;
    startup.StartupInfo.hStdOutput = child_out;
    startup.StartupInfo.hStdError = child_error;
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limit = {0};
    limit.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    pipe->job = CreateJobObjectW(NULL,NULL);
    if (!pipe->job || !SetInformationJobObject(pipe->job,JobObjectExtendedLimitInformation,&limit,sizeof(limit))) goto cleanup;
    if (!CreateProcessW(path,NULL,NULL,NULL,TRUE,EXTENDED_STARTUPINFO_PRESENT|CREATE_SUSPENDED|CREATE_NO_WINDOW,
        NULL,cwd,&startup.StartupInfo,&child)) goto cleanup;
    pipe->process = child.hProcess;
    if (!AssignProcessToJobObject(pipe->job,pipe->process) || ResumeThread(child.hThread) == (DWORD)-1) goto cleanup;
    pipe->deadline = GetTickCount64() + 2000;
    ok = true;
cleanup:
    *error = ok ? ERROR_SUCCESS : GetLastError();
    dispose(&child.hThread);
    dispose(&child_in); dispose(&child_out); dispose(&child_error);
    if (initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
    free(startup.lpAttributeList);
    if (ok) return pipe;
    if (pipe->process) TerminateProcess(pipe->process,1);
    moon_pipe_close(pipe);
    return NULL;
}
bool moon_pipe_send(MoonPipe *pipe, const char *line) {
    size_t length = strlen(line);
    DWORD sent = 0;
    return length > 0 && length < FRAME_LIMIT && GetTickCount64() < pipe->deadline &&
        WriteFile(pipe->input,line,(DWORD)length,&sent,NULL) && sent == length;
}
int moon_pipe_read_active(MoonPipe *pipe, char *data, size_t capacity, MoonPipeActive active, const void *context) {
    size_t received = 0;
    while (GetTickCount64() < pipe->deadline) {
        if (pipe->consumed == pipe->buffered) {
            if (active && !active(context)) return -2;
            DWORD available = 0, got = 0;
            if (!PeekNamedPipe(pipe->output,NULL,0,NULL,&available,NULL))
                return WaitForSingleObject(pipe->process,10) == WAIT_OBJECT_0 ? -3 : -1;
            if (!available) {
                if (WaitForSingleObject(pipe->process,12) != WAIT_OBJECT_0) continue;
                // The child can flush its final response and exit while we wait.
                // Drain the pipe before reporting that it stopped.
                if (!PeekNamedPipe(pipe->output,NULL,0,NULL,&available,NULL) || !available) return -3;
            }
            DWORD requested = available < sizeof(pipe->bytes) ? available : sizeof(pipe->bytes);
            if (!ReadFile(pipe->output,pipe->bytes,requested,&got,NULL) || !got) return -1;
            pipe->buffered = got;
            pipe->consumed = 0;
        }
        char ch = pipe->bytes[pipe->consumed++];
        if (ch == '\n') {
            if (received && data[received-1] == '\r') --received;
            data[received] = 0;
            return (int)received;
        }
        if (!ch || received + 1 >= capacity || received >= FRAME_LIMIT - 1) return -1;
        data[received++] = ch;
    }
    return -2;
}
int moon_pipe_read(MoonPipe *pipe, char *data, size_t capacity) {
    return moon_pipe_read_active(pipe,data,capacity,NULL,NULL);
}
bool moon_pipe_close(MoonPipe *pipe) {
    dispose(&pipe->input); dispose(&pipe->output);
    DWORD code = STILL_ACTIVE;
    bool clean = pipe->process && WaitForSingleObject(pipe->process,75) == WAIT_OBJECT_0 &&
        GetExitCodeProcess(pipe->process,&code) && code == 0;
    dispose(&pipe->job);
    dispose(&pipe->process);
    free(pipe);
    return clean;
}
