#!/bin/bash -e

# Generate the locales used by the CPZ interface selector. The image can switch
# between every language offered on the website without downloading anything
# at runtime. LOCALE_DEFAULT from the build config is generated separately by
# stage0/01-locale.
on_chroot <<'CHROOT'
set -e
for locale in \
	en_US.UTF-8 uk_UA.UTF-8 pl_PL.UTF-8 de_DE.UTF-8 fr_FR.UTF-8 \
	es_ES.UTF-8 it_IT.UTF-8 pt_BR.UTF-8 tr_TR.UTF-8 ja_JP.UTF-8 \
	zh_CN.UTF-8; do
	grep -q "^${locale}[[:space:]]" /etc/locale.gen ||
		printf '%s UTF-8\n' "$locale" >>/etc/locale.gen
done
locale-gen
CHROOT
