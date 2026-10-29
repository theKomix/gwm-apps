#!/usr/bin/env bash
# Проверяет релиз витрины gwm-apps перед публикацией (черновик) или после неё.
#
# Использование:
#   tools/verify-release.sh <тег>                 файлы берутся из релиза (черновика или опубликованного) через gh
#   tools/verify-release.sh <тег> --dir <папка>   проверить файлы из локальной папки, без скачивания релиза
#   Ключ --no-prev пропускает сравнение versionCode с предыдущей версией (оно качает APK прошлого релиза).
#
# Проверяет у каждого APK релиза:
#   0. состав релиза: у gwm-install -hu- и -phone- по одному, плюс не больше одного -lite- (облегчённый клиент, с 0.2.1), других APK нет; у остальных ровно один; .sha256 и .sig только к своему APK;
#      ключи tools/catalog-keys.txt совпадают с CatalogSig.KEYS в ../gwm-install (если он рядом);
#   1. рядом есть <имя>.sha256 и <имя>.sig;
#   2. SHA-256 файла совпадает с первым словом из <имя>.sha256;
#   3. подпись из .sig (ECDSA P-256, SHA-256, DER в base64) сходится по строке
#      «gwm-apps/1\n<тег релиза>\n<имя APK>\n<SHA-256 файла>\n» с любым из открытых ключей tools/catalog-keys.txt;
#   4. пакет и версия внутри APK (aapt2 dump badging) совпадают с ожидаемыми: пакет — из catalog.json по префиксу
#      тега (у менеджера -hu- → com.tank300.install, -phone- → com.tank300.installer), версия — из тега;
#   5. versionCode строго больше, чем у предыдущей опубликованной версии того же приложения
#      (равный код ГУ сочтёт «той же версией», и обновление не поставится).
# Код выхода 0 и «Можно публиковать» только если всё сошлось, иначе ненулевой код и список проблем.
#
# Порядок выпуска релиза (релизы неизменяемые: после публикации файл не заменить, тег не передвинуть):
#   1. подписать ЛОКАЛЬНЫЙ APK: gwm-install/tools/catalog-sign.sh <тег> <apk>  (пишет <apk>.sig),
#      сумму записать: (cd <папка> && shasum -a 256 <apk> > <apk>.sha256);
#   2. gh release create <тег> <apk> <apk>.sha256 <apk>.sig --repo theKomix/gwm-apps --draft --title … --notes-file …;
#   3. tools/verify-release.sh <тег>;
#   4. только после «Можно публиковать» и по слову автора: gh release edit <тег> --repo theKomix/gwm-apps --draft=false;
#   5. python3 -I tools/sync.py (обновит страницу и таблицу; сам проверяет наличие .sha256 и .sig у каждого релиза).
# Закрытый ключ catalog.pem лежит у автора вне репозиториев; этот скрипт его не использует.
set -u

REPO="theKomix/gwm-apps"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
KEYFILE="$HERE/catalog-keys.txt"

TAG=""; DIR=""; NOPREV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) DIR="${2:-}"; shift 2 ;;
    --no-prev) NOPREV=1; shift ;;
    -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Неизвестный ключ $1" >&2; exit 2 ;;
    *) TAG="$1"; shift ;;
  esac
done
[ -n "$TAG" ] || { echo "Использование: $0 <тег> [--dir <папка>] [--no-prev]" >&2; exit 2; }

FAILS=0
bad() { echo "  ✗ $*"; FAILS=$((FAILS+1)); }
good() { echo "  ✓ $*"; }

case "$TAG" in
  dimmer-v*)      APP=dimmer;      VER="${TAG#dimmer-v}";      PREFIX="dimmer-v" ;;
  tboxrules-v*)   APP=tboxrules;   VER="${TAG#tboxrules-v}";   PREFIX="tboxrules-v" ;;
  comfort-v*)     APP=comfort;     VER="${TAG#comfort-v}";     PREFIX="comfort-v" ;;
  gwm-install-v*) APP=gwm-install; VER="${TAG#gwm-install-v}"; PREFIX="gwm-install-v" ;;
  offroad-lite-v*) APP=offroad-lite; VER="${TAG#offroad-lite-v}"; PREFIX="offroad-lite-v" ;;
  offroad-v*)     APP=offroad;     VER="${TAG#offroad-v}";     PREFIX="offroad-v" ;;
  *) echo "Тег $TAG не похож на <приложение>-v<версия> (dimmer, tboxrules, comfort, gwm-install, offroad, offroad-lite)" >&2; exit 2 ;;
esac

for t in gh openssl shasum python3 base64; do
  command -v "$t" >/dev/null 2>&1 || { echo "Нет программы $t" >&2; exit 2; }
done
AAPT="$(ls "$HOME"/Library/Android/sdk/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1)"
[ -z "$AAPT" ] && AAPT="$(command -v aapt2 || true)"
[ -n "$AAPT" ] || { echo "Нет aapt2 (Android SDK build-tools)" >&2; exit 2; }
[ -f "$KEYFILE" ] || { echo "Нет файла ключей $KEYFILE" >&2; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- файлы релиза ---
if [ -n "$DIR" ]; then
  [ -d "$DIR" ] || { echo "Нет папки $DIR" >&2; exit 2; }
  WORK="$DIR"
  echo "Проверка $TAG по локальной папке $DIR"
else
  WORK="$TMP/release"; mkdir -p "$WORK"
  echo "Проверка $TAG: скачиваю файлы релиза"
  if ! gh release download "$TAG" --repo "$REPO" -D "$WORK" >/dev/null 2>&1; then
    # черновик по тегу gh может не найти: берём по id из списка релизов
    ID="$(gh api "repos/$REPO/releases" --paginate --jq ".[]|select(.tag_name==\"$TAG\")|.id" 2>/dev/null | head -1)"
    [ -n "$ID" ] || { echo "Релиз $TAG не найден (ни опубликованный, ни черновик)" >&2; exit 2; }
    gh api "repos/$REPO/releases/$ID" --jq '.assets[]|"\(.id) \(.name)"' | while read -r AID ANAME; do
      gh api -H "Accept: application/octet-stream" "repos/$REPO/releases/assets/$AID" > "$WORK/$ANAME"
    done
  fi
fi

APKS="$(cd "$WORK" && ls ./*.apk 2>/dev/null | sed 's#^\./##')"
[ -n "$APKS" ] || { echo "В релизе нет ни одного APK" >&2; exit 1; }

# состав релиза: у менеджера оба APK (-hu- и -phone-), у остальных ровно один; .sha256 и .sig только к своему APK
echo "Состав релиза"
NAPK="$(printf '%s\n' "$APKS" | grep -c .)"
if [ "$APP" = "gwm-install" ]; then
  NHU="$(printf '%s\n' "$APKS" | grep -c -e '-hu-')"; NPH="$(printf '%s\n' "$APKS" | grep -c -e '-phone-')"
  NLT="$(printf '%s\n' "$APKS" | grep -c -e '-lite-')"
  if [ "$NHU" = 1 ] && [ "$NPH" = 1 ] && [ "$NLT" -le 1 ] && [ "$NAPK" = $((2+NLT)) ]; then
    if [ "$NLT" = 1 ]; then good "три APK менеджера: -hu-, -phone- и -lite-"; else good "два APK менеджера: -hu- и -phone-"; fi
  else bad "у релиза менеджера должны быть -hu- и -phone- по одному и не больше одного -lite- (сейчас: всего $NAPK, -hu- $NHU, -phone- $NPH, -lite- $NLT)"; fi
else
  if [ "$NAPK" = 1 ]; then good "один APK"; else bad "у релиза $APP должен быть ровно один APK, сейчас $NAPK"; fi
fi
for X in $(cd "$WORK" && ls ./*.sig ./*.sha256 2>/dev/null | sed 's#^\./##'); do
  B="${X%.sig}"; B="${B%.sha256}"
  case "$B" in *.apk) [ -f "$WORK/$B" ] && continue ;; esac
  bad "файл $X без своего APK ($B)"
done

# ключи в tools/catalog-keys.txt должны совпадать с CatalogSig.KEYS в gwm-install (иначе верные подписи будут отвергаться или неверные приниматься)
echo "Ключи"
SIGJAVA="$ROOT/../gwm-install/common/src/com/tank300/catalog/CatalogSig.java"
if [ -f "$SIGJAVA" ]; then
  KA="$(grep -v '^[[:space:]]*#' "$KEYFILE" | grep -v '^[[:space:]]*$' | sort)"
  KB="$(sed -n '/KEYS *= *{/,/};/p' "$SIGJAVA" | grep -o '"[A-Za-z0-9+/=]\{20,\}"' | tr -d '"' | sort)"
  if [ "$KA" = "$KB" ]; then good "ключи в catalog-keys.txt совпадают с CatalogSig.KEYS"
  else bad "ключи в catalog-keys.txt и в CatalogSig.KEYS (gwm-install) расходятся: приведите их к одному набору"; fi
else
  echo "  ключи: сверка с CatalogSig.java пропущена (рядом нет ../gwm-install)"
fi

# открытые ключи → PEM
KEYN=0
grep -v '^[[:space:]]*#' "$KEYFILE" | grep -v '^[[:space:]]*$' | while read -r K; do
  KEYN=$((KEYN+1)); printf '%s' "$K" | base64 -d > "$TMP/k$KEYN.der" 2>/dev/null \
    && openssl pkey -pubin -inform DER -in "$TMP/k$KEYN.der" -out "$TMP/k$KEYN.pem" 2>/dev/null
done
ls "$TMP"/k*.pem >/dev/null 2>&1 || { echo "Не удалось разобрать открытые ключи из $KEYFILE" >&2; exit 2; }

pkg_expected() {  # $1 = имя APK
  if [ "$APP" = "gwm-install" ]; then
    case "$1" in
      *-hu-*)    echo com.tank300.install ;;
      *-phone-*|*-lite-*) echo com.tank300.installer ;;
      *) echo "" ;;
    esac
  else
    python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["package"])' "$ROOT/catalog.json" "$APP" 2>/dev/null
  fi
}

badging() {  # $1 = APK → «пакет versionCode versionName»
  "$AAPT" dump badging "$1" 2>/dev/null | sed -n "s/^package: name='\([^']*\)' versionCode='\([^']*\)' versionName='\([^']*\)'.*/\1 \2 \3/p" | head -1
}

for APK in $APKS; do
  echo "$APK"
  F="$WORK/$APK"
  SHA="$(shasum -a 256 "$F" | cut -d' ' -f1)"
  # 1-2. сумма
  if [ ! -f "$F.sha256" ]; then bad "нет файла $APK.sha256"
  else
    WANT="$(head -1 "$F.sha256" | awk '{print tolower($1)}')"
    if [ "$WANT" = "$SHA" ]; then good "сумма из .sha256 совпадает с файлом ($SHA)"; else bad "сумма из .sha256 ($WANT) не совпадает с файлом ($SHA)"; fi
  fi
  # 3. подпись
  if [ ! -f "$F.sig" ]; then bad "нет файла $APK.sig"
  else
    printf 'gwm-apps/1\n%s\n%s\n%s\n' "$TAG" "$APK" "$SHA" > "$TMP/msg"
    if ! base64 -d < "$F.sig" > "$TMP/sig" 2>/dev/null || [ ! -s "$TMP/sig" ]; then
      bad "$APK.sig не разбирается как base64"
    else
      OKSIG=0
      for P in "$TMP"/k*.pem; do
        if openssl dgst -sha256 -verify "$P" -signature "$TMP/sig" "$TMP/msg" >/dev/null 2>&1; then OKSIG=1; break; fi
      done
      if [ "$OKSIG" = 1 ]; then good "подпись сходится для тега $TAG и имени $APK"
      else bad "подпись НЕ сходится: сделана не для тега $TAG, не для имени $APK или не для этого содержимого файла"; fi
    fi
  fi
  # 4. пакет и версия
  read -r PKG VCODE VNAME <<EOF
$(badging "$F")
EOF
  if [ -z "${PKG:-}" ]; then bad "aapt2 не прочитал пакет и версию APK"
  else
    EXP="$(pkg_expected "$APK")"
    if [ -z "$EXP" ]; then bad "не знаю ожидаемый пакет для $APK"
    elif [ "$PKG" = "$EXP" ]; then good "пакет $PKG"
    else bad "пакет $PKG, ожидался $EXP"; fi
    if [ "$VNAME" = "$VER" ]; then good "версия $VNAME совпадает с тегом (versionCode $VCODE)"
    else bad "версия в APK $VNAME, в теге $VER"; fi
  fi
  echo "$APK $VCODE" >> "$TMP/codes"
done

# 5. versionCode не ниже предыдущей опубликованной версии
if [ "$NOPREV" = 1 ]; then
  echo "versionCode: сравнение с предыдущей версией пропущено (--no-prev)"
else
  PREV="$( (gh api "repos/$REPO/releases" --paginate --jq '.[]|select(.draft==false and .prerelease==false)|.tag_name' 2>/dev/null) \
    | grep "^$PREFIX" | grep -vx "$TAG" | sed "s/^$PREFIX//" | { cat; echo "$VER"; } | sort -V | awk -v v="$VER" '$0==v{print prev; exit} {prev=$0}')"
  if [ -z "$PREV" ]; then
    echo "versionCode: предыдущей опубликованной версии $APP нет, сравнивать не с чем"
  else
    echo "versionCode: сравнение с $PREFIX$PREV"
    PD="$TMP/prev"; mkdir -p "$PD"
    if ! gh release download "$PREFIX$PREV" --repo "$REPO" -D "$PD" --pattern '*.apk' >/dev/null 2>&1; then
      bad "не удалось скачать APK предыдущей версии $PREFIX$PREV"
    else
      while read -r APK CODE; do
        case "$APK" in *-hu-*) ROLE="*-hu-*.apk" ;; *-phone-*) ROLE="*-phone-*.apk" ;; *-lite-*) ROLE="*-lite-*.apk" ;; *) ROLE="*.apk" ;; esac
        PA="$(cd "$PD" && ls $ROLE 2>/dev/null | head -1)"
        # у первого релиза с облегчённым клиентом предыдущего -lite- нет: пакет тот же, что у -phone-
        [ -z "$PA" ] && case "$APK" in *-lite-*) PA="$(cd "$PD" && ls *-phone-*.apk 2>/dev/null | head -1)" ;; esac
        if [ -z "$PA" ]; then bad "у $PREFIX$PREV нет APK того же вида, что $APK"; continue; fi
        read -r _ PCODE _ <<EOF
$(badging "$PD/$PA")
EOF
        if [ "${CODE:-0}" -gt "${PCODE:-0}" ] 2>/dev/null; then good "$APK: versionCode $CODE больше, чем $PCODE у $PA"
        else bad "$APK: versionCode $CODE не больше, чем $PCODE у $PA ($PREFIX$PREV)"; fi
      done < "$TMP/codes"
    fi
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  echo "Можно публиковать: $TAG"
  exit 0
fi
echo "НЕЛЬЗЯ публиковать $TAG: проблем $FAILS"
exit 1
