#!/bin/bash -e

# Generate the locales used by the CPZ interface selector. The image can switch
# between English, Ukrainian and German without downloading anything at
# runtime. LOCALE_DEFAULT from the build config is generated separately by
# stage0/01-locale.
on_chroot <<'CHROOT'
set -e
for locale in en_US.UTF-8 uk_UA.UTF-8 de_DE.UTF-8; do
	grep -q "^${locale}[[:space:]]" /etc/locale.gen ||
		printf '%s UTF-8\n' "$locale" >>/etc/locale.gen
done
locale-gen
CHROOT
