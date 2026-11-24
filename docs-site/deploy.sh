#!/bin/sh
set -eu

root=/srv/moon-browser-docs
config=/etc/caddy/Caddyfile
snippet=/etc/caddy/moon-browser-docs-site.caddy
import="import $snippet"
mkdir -p "$root/releases"
exec 9>"$root/deploy.lock"
flock 9

stage=$(mktemp -d "$root/releases/site.XXXXXXXX")
candidate=
backup=
activated=false
cleanup() {
    [ -z "$candidate" ] || rm -f -- "$candidate"
    [ -z "$backup" ] || rm -f -- "$backup"
    [ "$activated" = true ] || rm -rf -- "$stage"
}
trap cleanup EXIT
tar -xzf "$1" -C "$stage"
for page in index guide protocol-v1 api lua-userscripts plugin-system lua-demo extension-pages devtools market history blocker library site-data reading recent-tabs privacy task-manager; do
    test -s "$stage/$page.html"
done
test -s "$stage/welcome.user.lua"
test -s "$stage/plugin-market/catalog.json"
chmod -R a+rX "$stage"

if ! grep -Fxq "$import" "$config"; then
    if [ -e "$snippet" ]; then
        echo "Unexpected existing Caddy snippet $snippet" >&2
        exit 1
    fi
    candidate=$(mktemp /etc/caddy/moon-browser-docs-config.XXXXXXXX)
    backup=$(mktemp /etc/caddy/moon-browser-docs-backup.XXXXXXXX)
    cp -p -- "$config" "$backup"
    cat > "$snippet" <<'CADDY'
docs.browser.moonl.cloud {
    root * /srv/moon-browser-docs/public
    encode zstd gzip
    header Cache-Control "no-cache"
    file_server
}
CADDY
    cat "$config" > "$candidate"
    printf '\n%s\n' "$import" >> "$candidate"
    if ! caddy validate --config "$candidate" --adapter caddyfile; then
        rm -f -- "$snippet"
        exit 1
    fi
    chmod --reference="$config" "$candidate"
    mv -T -- "$candidate" "$config"
    candidate=
    if ! systemctl reload caddy; then
        mv -T -- "$backup" "$config"
        backup=
        rm -f -- "$snippet"
        systemctl reload caddy
        exit 1
    fi
fi

previous=$(readlink "$root/public" || :)
legacy=$(readlink "$root/current" || :)
ln -s "$stage" "$stage.link"
mv -Tf -- "$stage.link" "$root/public"
activated=true
find "$root/releases" -mindepth 1 -maxdepth 1 -type d -name 'site.????????' \
    ! -path "$stage" ! -path "$previous" ! -path "$legacy" -exec rm -rf -- {} +
printf '%s\n' 'https://docs.browser.moonl.cloud/'
