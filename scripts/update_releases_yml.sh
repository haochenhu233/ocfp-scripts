#!/usr/bin/env bash
#
# update_releases_yml.sh
#
# Update an OCFP-style releases.yml (the override we layer on top of cf-deployment.yml)
# from a directory of downloaded release tarballs.
#
# For each release section (matched by `name:`) it will, based on the tarball found:
#   - set  version:            -> the release version parsed from the filename
#   - set  url:                -> <PREFIX>/<actual-tarball-filename>
#   - set  sha1:               -> "sha256:<hash>"   (ONLY if a sha1: line already exists)
#   - set  stemcell.os / .version   (ONLY for pre-compiled releases, and ONLY if an
#                                    active stemcell: block already exists)
#
# It never uncomments lines and never adds keys that are not already present, so a
# commented-out sha1:/stemcell: (typical for source releases) is left alone.
#
# Tarball filename conventions:
#   pre-compiled : <name>-<version>-ubuntu-noble-1.333-<YYYY-MM-DD>-<n>-<n>.tgz
#   source       : <name>-release-<version>.tgz
#
# Usage:
#   update_releases_yml.sh [--dry-run] [--os-style short|full] [--prefix PATH] \
#                          <releases-dir> <releases.yml>
#
set -euo pipefail
shopt -s nullglob

DRY_RUN=0
OS_STYLE="short"                       # short: "noble"  | full: "ubuntu-noble"
PREFIX="file:///opt/ocfp/bosh/releases"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; shift ;;
    --os-style) OS_STYLE="${2:-}"; shift 2 ;;
    --prefix)   PREFIX="${2:-}"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1" ;;
    *)  break ;;
  esac
done

[[ $# -eq 2 ]] || die "expected 2 positional args: <releases-dir> <releases.yml> (see --help)"
DIR="$1"; YML="$2"
[[ -d "$DIR" ]] || die "not a directory: $DIR"
[[ -f "$YML" ]] || die "not a file: $YML"
[[ "$OS_STYLE" == short || "$OS_STYLE" == full ]] || die "--os-style must be short or full"

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# ---- collect release names from the yaml (bash 3.2: no mapfile) -------------
NAMES=()
while IFS= read -r n; do NAMES+=("$n"); done < <(
  awk '/^-[[:space:]]+name:/{
         sub(/^-[[:space:]]+name:[[:space:]]*/,"")
         sub(/#.*/,""); sub(/[[:space:]]*$/,"")
         gsub(/^"|"$/,"")
         if (length) print
       }' "$YML"
)
[[ ${#NAMES[@]} -gt 0 ]] || die "no '- name:' entries found in $YML"

# process longest names first so a file is claimed by the most specific release
NAMES_BY_LEN=()
while IFS= read -r n; do NAMES_BY_LEN+=("$n"); done < <(
  for n in "${NAMES[@]}"; do printf '%d\t%s\n' "${#n}" "$n"; done | sort -rn | cut -f2-
)

# ---- build metadata (name -> version/url/os/sver/sha/compiled) --------------
META="$(mktemp)"
USED="$(mktemp)"                        # newline-list of claimed file paths (bash 3.2: no assoc arrays)
trap 'rm -f "$META" "$USED"' EXIT

for name in "${NAMES_BY_LEN[@]}"; do
  comp_matches=(); src_match=""
  for f in "$DIR/$name-"*.tgz; do
    grep -Fxq "$f" "$USED" && continue
    B="$(basename "$f")"
    rest="${B#"${name}-"}"
    if [[ $rest =~ ^release-([0-9].*)\.tgz$ ]]; then
      src_match="$f"
    elif [[ $rest =~ ^([0-9][^[:space:]]*)-(ubuntu-[a-z0-9]+|windows-[0-9]+)-([0-9]+(\.[0-9]+)*)(-.*)?\.tgz$ ]]; then
      comp_matches+=("$f")
    fi
  done

  file=""; compiled=0; ver=""; os=""; sver=""
  if [[ ${#comp_matches[@]} -gt 0 ]]; then
    # newest compile date wins (date + trailing timestamp sort lexically)
    file="$(printf '%s\n' "${comp_matches[@]}" | sort | tail -n1)"
    [[ ${#comp_matches[@]} -gt 1 ]] && info "NOTE: $name: ${#comp_matches[@]} compiled tarballs, using $(basename "$file")"
    B="$(basename "$file")"; rest="${B#"${name}-"}"
    [[ $rest =~ ^([0-9][^[:space:]]*)-(ubuntu-[a-z0-9]+|windows-[0-9]+)-([0-9]+(\.[0-9]+)*)(-.*)?\.tgz$ ]] || die "internal: reparse failed for $B"
    compiled=1
    ver="${BASH_REMATCH[1]}"
    stemos_full="${BASH_REMATCH[2]}"
    sver="${BASH_REMATCH[3]}"
    if [[ "$OS_STYLE" == short ]]; then os="${stemos_full#ubuntu-}"; else os="$stemos_full"; fi
  elif [[ -n "$src_match" ]]; then
    file="$src_match"
    B="$(basename "$file")"; rest="${B#"${name}-"}"
    [[ $rest =~ ^release-([0-9].*)\.tgz$ ]] || die "internal: reparse failed for $B"
    ver="${BASH_REMATCH[1]}"
  else
    info "WARN: $name: no matching tarball in $DIR (left unchanged)"
    continue
  fi

  printf '%s\n' "$file" >> "$USED"
  sha="$(sha256_of "$file")"
  url="$PREFIX/$(basename "$file")"
  printf '%s\t%d\t%s\t%s\t%s\t%s\t%s\n' "$name" "$compiled" "$ver" "$url" "$os" "$sver" "$sha" >> "$META"

  if [[ $compiled -eq 1 ]]; then
    info "OK   $name  compiled  v$ver  stemcell $os/$sver"
  else
    info "OK   $name  source    v$ver"
  fi
done

# ---- rewrite the yaml -------------------------------------------------------
transform() {
  awk -F'\t' -v META="$META" '
    FILENAME==META {
      m_have[$1]=1; m_comp[$1]=$2; m_ver[$1]=$3; m_url[$1]=$4; m_os[$1]=$5; m_sver[$1]=$6; m_sha[$1]=$7
      next
    }
    function flush(){
      if (cur=="") return
      if (!m_have[cur]) return
      if (m_comp[cur]=="1" && (!got_os[cur] || !got_sv[cur]))
        printf("WARN: %s: compiled release but no active stemcell os/version line to update\n", cur) > "/dev/stderr"
    }
    {
      line=$0
      if (line ~ /^-[[:space:]]+name:/) {
        flush()
        tmp=line
        sub(/^-[[:space:]]+name:[[:space:]]*/,"",tmp); sub(/#.*/,"",tmp)
        sub(/[[:space:]]*$/,"",tmp); gsub(/^"|"$/,"",tmp)
        cur=tmp; in_stem=0
        print line; next
      }
      if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) { print line; next }

      match(line,/^[[:space:]]*/); ind=RLENGTH; indent=substr(line,1,ind)
      content=substr(line,ind+1)
      key=content; sub(/:.*/,"",key); sub(/[[:space:]].*/,"",key)

      if (in_stem && ind <= stem_ind) in_stem=0
      if (ind==0) { in_stem=0; print line; next }

      if (!in_stem && key=="stemcell") { in_stem=1; stem_ind=ind; print line; next }

      if (in_stem) {
        if (m_have[cur] && m_comp[cur]=="1") {
          if (key=="os")      { got_os[cur]=1; print indent "os: " m_os[cur];              next }
          if (key=="version") { got_sv[cur]=1; print indent "version: \"" m_sver[cur] "\""; next }
        }
        print line; next
      }

      if (m_have[cur]) {
        if (key=="version") { print indent "version: " m_ver[cur];        next }
        if (key=="url")     { print indent "url: " m_url[cur];            next }
        if (key=="sha1")    { print indent "sha1: sha256:" m_sha[cur];    next }
      }
      print line
    }
    END { flush() }
  ' "$META" "$YML"
}

if [[ $DRY_RUN -eq 1 ]]; then
  info "--- dry run: writing updated yaml to stdout, $YML NOT modified ---"
  transform
else
  OUT="$(mktemp)"
  transform > "$OUT"
  cp "$YML" "$YML.bak"
  mv "$OUT" "$YML"
  info "updated $YML (backup at $YML.bak)"
fi
