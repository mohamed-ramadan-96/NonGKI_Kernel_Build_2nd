#!/bin/bash
# Stronger KernelSU / SUSFS / NoMount hook cleaner.
# Run from the kernel root (device_kernel).
# 1) Removes KernelSU folders and SUSFS-only files.
# 2) Removes NoMount folders, symlinks and headers (anything named *nomount*).
# 3) Strips every #if/#ifdef/#ifndef block guarded by CONFIG_KSU* or CONFIG_NOMOUNT (nesting-safe).
#    The #else branch is kept, since it is the stock code path.
# 4) Removes KSU / NoMount lines from Makefile / Kbuild / Kconfig.
# 5) Verifies that no ksu_handle_ calls and no NoMount includes remain.

status=0

KSU_FOLDERS=("drivers/kernelsu" "KernelSU" "KernelSU-Next")
KSU_ONLY_FILES=("fs/susfs.c" "fs/sus_su.c" "include/linux/susfs.h" "include/linux/susfs_def.h")
EXCLUDES=(--exclude-dir=out --exclude-dir=.git --exclude-dir=KernelSU --exclude-dir=KernelSU-Next --exclude-dir=kernelsu --exclude-dir=NoMount)

echo "== 1. Removing KernelSU folders =="
for d in "${KSU_FOLDERS[@]}"; do
    rm -rf "$d"
    if [ -e "$d" ] || [ -L "$d" ]; then
        echo "[-] Could not remove $d"; status=1
    else
        echo "[+] Removed $d"
    fi
done

echo "== 2. Removing SUSFS-only files =="
for f in "${KSU_ONLY_FILES[@]}"; do
    rm -f "$f"
    if [ -e "$f" ]; then
        echo "[-] Could not remove $f"; status=1
    else
        echo "[+] Removed $f"
    fi
done

echo "== 3. Removing NoMount folders, symlinks and headers =="
while IFS= read -r p; do
    rm -rf "$p"
    if [ -e "$p" ] || [ -L "$p" ]; then
        echo "[-] Could not remove $p"; status=1
    else
        echo "[+] Removed $p"
    fi
done < <(find . -path ./out -prune -o -path ./.git -prune -o -iname '*nomount*' -print 2>/dev/null)

echo "== 3b. Removing CONFIG_NOMOUNT from defconfig =="
DEFCONFIG="arch/arm64/configs/vendor/alioth_defconfig"
if [ -f "$DEFCONFIG" ]; then
    before=$(grep -cE '^(# )?CONFIG_NOMOUNT' "$DEFCONFIG")
    sed -i -E '/^(# )?CONFIG_NOMOUNT([= ]|$)/d' "$DEFCONFIG"
    after=$(grep -cE '^(# )?CONFIG_NOMOUNT' "$DEFCONFIG")
    echo "[+] Removed $((before - after)) CONFIG_NOMOUNT line(s) from $DEFCONFIG"
else
    echo "[-] $DEFCONFIG not found"; status=1
fi

echo "== 4. Stripping CONFIG_KSU / CONFIG_NOMOUNT preprocessor blocks =="
while IFS= read -r f; do
    tmp=$(mktemp)
    if awk '
    function emitting(   i, ok, e) {
        ok = 1
        for (i = 1; i <= n; i++) {
            if (ks[i]) {
                e = el[i] ? !ie[i] : ie[i]
                if (!e) ok = 0
            }
        }
        return ok
    }
    /^[[:space:]]*#[[:space:]]*if/ {
        if ($0 ~ /CONFIG_(KSU|NOMOUNT)/) {
            n++; ks[n] = 1; el[n] = 0
            ie[n] = ($0 ~ /ifndef|![[:space:]]*defined|![[:space:]]*IS_ENABLED/) ? 1 : 0
            next
        }
        if (emitting()) print
        n++; ks[n] = 0; el[n] = 0; ie[n] = 0
        next
    }
    /^[[:space:]]*#[[:space:]]*(elif|else)/ {
        if (n > 0 && ks[n]) { el[n] = 1; next }
        if (emitting()) print
        next
    }
    /^[[:space:]]*#[[:space:]]*endif/ {
        wasksu = 0
        if (n > 0) { wasksu = ks[n]; n-- }
        if (!wasksu && emitting()) print
        next
    }
    { if (emitting()) print }
    ' "$f" > "$tmp"; then
        if ! cmp -s "$f" "$tmp"; then
            cat "$tmp" > "$f"
            echo "[+] Cleaned $f"
        fi
    else
        echo "[-] awk failed on $f"; status=1
    fi
    rm -f "$tmp"
done < <(grep -rlE --include='*.c' --include='*.h' "${EXCLUDES[@]}" 'CONFIG_(KSU|NOMOUNT)' . 2>/dev/null)

echo "== 5. Removing KSU / NoMount lines from Makefile / Kbuild / Kconfig =="
while IFS= read -r f; do
    sed -i -E '/CONFIG_(KSU|NOMOUNT)/d;/kernelsu|nomount/Id' "$f"
    echo "[+] Cleaned $f"
done < <(grep -rlIiE --include=Makefile --include=Kbuild --include=Kconfig 'CONFIG_(KSU|NOMOUNT)|kernelsu|nomount' "${EXCLUDES[@]}" . 2>/dev/null)

echo "== 6. Verifying =="
calls=$(grep -rn -E 'ksu_handle_' --include='*.c' --include='*.h' "${EXCLUDES[@]}" . 2>/dev/null | head -20)
if [ -n "$calls" ]; then
    echo "[-] Leftover ksu_handle_ calls (link will fail):"
    echo "$calls"
    status=1
else
    echo "[+] No ksu_handle_ calls left"
fi

nm_inc=$(grep -rn -E '#include.*nomount|nomount_' --include='*.c' --include='*.h' "${EXCLUDES[@]}" . 2>/dev/null | head -20)
if [ -n "$nm_inc" ]; then
    echo "[-] Leftover NoMount references (may break the build):"
    echo "$nm_inc"
    status=1
else
    echo "[+] No NoMount references left in source"
fi

refs=$(grep -rlE 'CONFIG_(KSU|NOMOUNT)' --include='*.c' --include='*.h' --include=Makefile --include=Kbuild --include=Kconfig "${EXCLUDES[@]}" . 2>/dev/null | head -20)
if [ -n "$refs" ]; then
    echo "[-] CONFIG_KSU / CONFIG_NOMOUNT still referenced in:"
    echo "$refs"
else
    echo "[+] No CONFIG_KSU / CONFIG_NOMOUNT references left in source"
fi

exit $status