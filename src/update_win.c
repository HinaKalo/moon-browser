#include "win_internal.h"
#include <winhttp.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <string.h>
#include <wchar.h>

typedef struct UpdateHttp {
    HINTERNET session, server, request;
} UpdateHttp;

static void close_http(UpdateHttp *http) {
    if (http->request) WinHttpCloseHandle(http->request);
    if (http->server) WinHttpCloseHandle(http->server);
    if (http->session) WinHttpCloseHandle(http->session);
}

static int get(UpdateHttp *http, const wchar_t *host, const char *path) {
    wchar_t request_path[512];
    if (!path || path[0] != '/' || !moon_utf16(path, request_path, ARRAYSIZE(request_path))) return 0;
    http->session = WinHttpOpen(L"MoonBrowser Update", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!http->session || !WinHttpSetTimeouts(http->session, 10000, 10000, 15000, 15000)) return 0;
    http->server = WinHttpConnect(http->session, host, INTERNET_DEFAULT_HTTPS_PORT, 0);
    if (!http->server) return 0;
    http->request = WinHttpOpenRequest(http->server, L"GET", request_path, NULL,
        WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!http->request) return 0;
    DWORD redirects = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(http->request, WINHTTP_OPTION_REDIRECT_POLICY, &redirects, sizeof(redirects))) return 0;
    if (!WinHttpSendRequest(http->request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(http->request, NULL)) return 0;
    DWORD status = 0, length = sizeof(status);
    if (!WinHttpQueryHeaders(http->request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
        WINHTTP_HEADER_NAME_BY_INDEX, &status, &length, WINHTTP_NO_HEADER_INDEX)) return 0;
    return (int)status;
}

static int read_response(const wchar_t *host, const char *path, char *buffer, size_t capacity, size_t *length) {
    UpdateHttp http = {0};
    int status = get(&http, host, path);
    *length = 0;
    if (status == 200) {
        const uint64_t deadline = GetTickCount64() + 30000;
        for (;;) {
            DWORD received = 0;
            if (GetTickCount64() > deadline || !WinHttpReadData(http.request, buffer + *length,
                (DWORD)(capacity - *length), &received)) { status = 0; break; }
            if (!received) break;
            *length += received;
            if (*length == capacity) { status = 0; break; }
        }
    }
    close_http(&http);
    return status;
}
int moon_update_read(const char *path, char *buffer, size_t capacity, size_t *length) {
    return read_response(L"release.moonl.cloud",path,buffer,capacity,length);
}
bool moon_market_read(char *buffer, size_t capacity, size_t *length) {
    return read_response(L"docs.browser.moonl.cloud","/plugin-market/catalog.json",buffer,capacity,length) == 200;
}

static bool plain(const wchar_t *path, bool directory) {
    DWORD flags = GetFileAttributesW(path);
    return flags != INVALID_FILE_ATTRIBUTES && !(flags & FILE_ATTRIBUTE_REPARSE_POINT) &&
        !!(flags & FILE_ATTRIBUTE_DIRECTORY) == directory;
}

static bool update_directory(wchar_t *path, size_t capacity) {
    wchar_t profile[2048];
    if (!moon_utf16(moon_profile_dir(), profile, ARRAYSIZE(profile)) || !plain(profile, true) ||
        !moon_path(path, capacity, profile, L"updates")) return false;
    if (!CreateDirectoryW(path, NULL) && GetLastError() != ERROR_ALREADY_EXISTS) return false;
    return plain(path, true);
}

static const wchar_t *filename(bool portable) {
    return portable ? L"MoonBrowser-Portable-win-x64.zip" : L"MoonBrowser-Installer-win-x64.exe";
}

static bool matches(const wchar_t *path, uint64_t bytes, const uint8_t *expected) {
    if (!plain(path, false)) return false;
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, NULL);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER length;
    BCRYPT_ALG_HANDLE provider = NULL;
    BCRYPT_HASH_HANDLE hash = NULL;
    bool valid = false;
    if (!GetFileSizeEx(file, &length) || (uint64_t)length.QuadPart != bytes ||
        BCryptOpenAlgorithmProvider(&provider, BCRYPT_SHA256_ALGORITHM, NULL, 0) < 0 ||
        BCryptCreateHash(provider, &hash, NULL, 0, NULL, 0, 0) < 0) goto cleanup;
    uint8_t buffer[32768], digest[32];
    DWORD received;
    do {
        if (!ReadFile(file, buffer, sizeof(buffer), &received, NULL) ||
            BCryptHashData(hash, buffer, received, 0) < 0) goto cleanup;
    } while (received);
    valid = BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0 && memcmp(digest, expected, 32) == 0;
cleanup:
    if (hash) BCryptDestroyHash(hash);
    if (provider) BCryptCloseAlgorithmProvider(provider, 0);
    CloseHandle(file);
    return valid;
}

static bool save_package(const char *path, HANDLE file, uint64_t expected) {
    UpdateHttp http = {0};
    bool ok = get(&http, L"release.moonl.cloud", path) == 200;
    const uint64_t deadline = GetTickCount64() + 120000;
    uint64_t total = 0;
    while (ok) {
        uint8_t buffer[32768];
        DWORD received = 0, written = 0;
        if (GetTickCount64() > deadline || !WinHttpReadData(http.request, buffer, sizeof(buffer), &received)) {
            ok = false;
            break;
        }
        if (!received) break;
        if (received > expected - total || !WriteFile(file, buffer, received, &written, NULL) || written != received) {
            ok = false;
            break;
        }
        total += received;
    }
    close_http(&http);
    return ok && total == expected && FlushFileBuffers(file);
}

bool moon_update_download(const char *path, bool portable, uint64_t size, const uint8_t *hash) {
    wchar_t directory[2048], target[2048], part[2048], lockfile[2048];
    if (!update_directory(directory, ARRAYSIZE(directory)) ||
        !moon_path(target, ARRAYSIZE(target), directory, filename(portable)) ||
        !moon_path(part, ARRAYSIZE(part), directory, L"update.part") ||
        !moon_path(lockfile, ARRAYSIZE(lockfile), directory, L"download.lock")) return false;
    HANDLE lock = CreateFileW(lockfile, GENERIC_READ | GENERIC_WRITE, 0, NULL, OPEN_ALWAYS,
        FILE_FLAG_OPEN_REPARSE_POINT, NULL);
    if (lock == INVALID_HANDLE_VALUE) return false;
    bool ok = matches(target, size, hash);
    if (!ok) {
        DWORD attributes = GetFileAttributesW(part);
        if (attributes == INVALID_FILE_ATTRIBUTES || (plain(part, false) && DeleteFileW(part))) {
            HANDLE file = CreateFileW(part, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
            if (file != INVALID_HANDLE_VALUE) {
                bool fetched = save_package(path, file, size);
                CloseHandle(file);
                ok = fetched && matches(part, size, hash) &&
                    MoveFileExW(part, target, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
                if (!ok) DeleteFileW(part);
            }
        }
    }
    CloseHandle(lock);
    return ok;
}

bool moon_update_open(bool portable, uint64_t size, const uint8_t *hash) {
    wchar_t directory[2048], file[2048];
    if (!update_directory(directory, ARRAYSIZE(directory)) ||
        !moon_path(file, ARRAYSIZE(file), directory, filename(portable)) || !matches(file, size, hash)) return false;
    return (INT_PTR)ShellExecuteW(NULL, L"open", portable ? directory : file, NULL, directory, SW_SHOWNORMAL) > 32;
}

static DWORD WINAPI run_worker(void *unused) {
    moon_update_worker();
    return 0;
}
bool moon_update_thread(void) {
    HANDLE thread = CreateThread(NULL, 0, run_worker, NULL, 0, NULL);
    if (!thread) return false;
    CloseHandle(thread);
    return true;
}
