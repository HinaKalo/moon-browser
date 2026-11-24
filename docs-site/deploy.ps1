#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
Push-Location -LiteralPath $PSScriptRoot
try {
    pnpm install --frozen-lockfile
    pnpm build
    $archive = [IO.Path]::GetTempFileName()
    try {
        tar -czf $archive -C .vitepress/dist .
        $remote = (ssh -o BatchMode=yes moon 'mktemp /tmp/moon-browser-docs.XXXXXXXX').Trim()
        if ($remote -cnotmatch '^/tmp/moon-browser-docs\.[A-Za-z0-9]{8}$') { throw 'Unexpected Moon staging path.' }
        try {
            scp -q -o BatchMode=yes $archive "moon:$remote"
            [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'deploy.sh')) |
                ssh -o BatchMode=yes moon "tr -d '\015' | sh -s -- $remote"
        } finally {
            ssh -o BatchMode=yes moon "rm -f -- $remote"
        }
    } finally { [IO.File]::Delete($archive) }
} finally {
    Pop-Location
}
