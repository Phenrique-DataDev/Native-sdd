#!/usr/bin/env bash
# statusline.sh — HUD do Claude Code (2 linhas), gêmeo POSIX/bash do statusline.ps1.
# Usado só quando `pwsh` NÃO está no PATH (o dispatch em settings.json prefere pwsh). Requer `jq`.
# Recebe o JSON de status no stdin. Doc do schema: https://code.claude.com/docs/en/statusline
#
# Temas (role-based): primary/accent/success/warning/caution/danger/muted/track.
#   Seleção, em ordem de precedência:
#     1) ~/.claude/statusline.theme   2) $SDD_STATUSLINE_THEME   3) 'dracula' (default)
#   Ver exemplo comentado em ~/.claude/statusline.theme.example.
# Guard de harness: sem `jq`, sem stdin, ou sem o schema do Claude Code → sai silencioso (exit 0),
#   p/ não poluir a status line de outra harness que porventura reutilize este comando.
set -u

input="$(cat)"

# --- guard de harness -----------------------------------------------------
command -v jq >/dev/null 2>&1 || exit 0
[ -n "$input" ] || exit 0
printf '%s' "$input" | jq -e 'has("model") or has("workspace") or has("context_window")' >/dev/null 2>&1 || exit 0

# --- temas (role-based) ---------------------------------------------------
theme_colors() {  # $1 = nome do tema; seta C_<role> como "R;G;B"
    case "$1" in
        onedark)
            C_primary="198;120;221"; C_accent="86;182;194";  C_success="152;195;121"
            C_warning="229;192;123"; C_caution="209;154;102"; C_danger="224;108;117"
            C_muted="92;99;112";     C_track="60;64;72" ;;
        catppuccin)  # Mocha
            C_primary="203;166;247"; C_accent="137;220;235"; C_success="166;227;161"
            C_warning="249;226;175"; C_caution="250;179;135"; C_danger="243;139;168"
            C_muted="108;112;134";   C_track="69;71;90" ;;
        *)  # dracula (default)
            C_primary="189;147;249"; C_accent="139;233;253"; C_success="80;250;123"
            C_warning="241;250;140"; C_caution="255;184;108"; C_danger="255;85;85"
            C_muted="98;114;164";    C_track="68;71;90" ;;
    esac
}
TH_LOW=40; TH_MID=60; TH_HIGH=80

# Nome do tema: env é o default; arquivo (linha `theme = X`, a última vence) sobrescreve.
THEME_NAME="${SDD_STATUSLINE_THEME:-dracula}"
THEME_FILE="$HOME/.claude/statusline.theme"
if [ -f "$THEME_FILE" ]; then
    tline="$(grep -iE '^[[:space:]]*theme[[:space:]]*=' "$THEME_FILE" | tail -n1)"
    [ -n "$tline" ] && THEME_NAME="$(printf '%s' "${tline#*=}" | tr -d '[:space:]' | tr 'A-Z' 'a-z')"
fi
theme_colors "$THEME_NAME"

# Overrides de role (R,G,B) e threshold (th_low/th_mid/th_high) vindos do arquivo.
if [ -f "$THEME_FILE" ]; then
    while IFS= read -r raw || [ -n "$raw" ]; do
        line="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$line" in ''|'#'*) continue ;; esac
        case "$line" in *=*) : ;; *) continue ;; esac
        key="$(printf '%s' "${line%%=*}" | sed 's/[[:space:]]*$//' | tr 'A-Z' 'a-z')"
        val="$(printf '%s' "${line#*=}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        case "$key" in
            th_low)  case "$val" in ''|*[!0-9]*) ;; *) TH_LOW="$val" ;;  esac ;;
            th_mid)  case "$val" in ''|*[!0-9]*) ;; *) TH_MID="$val" ;;  esac ;;
            th_high) case "$val" in ''|*[!0-9]*) ;; *) TH_HIGH="$val" ;; esac ;;
            primary|accent|success|warning|caution|danger|muted|track)
                rgb="$(printf '%s' "$val" | sed -n 's/^\([0-9]\{1,3\}\)[[:space:]]*,[[:space:]]*\([0-9]\{1,3\}\)[[:space:]]*,[[:space:]]*\([0-9]\{1,3\}\)$/\1;\2;\3/p')"
                [ -n "$rgb" ] && eval "C_$key=\"\$rgb\"" ;;
        esac
    done < "$THEME_FILE"
fi

# --- pintura --------------------------------------------------------------
# Modo de cor: NO_COLOR (no-color.org) → off | $SDD_STATUSLINE_COLOR (off|256|truecolor) |
# COLORTERM=truecolor/24bit → truecolor | default truecolor. 256 é opt-in (tmux sem RGB capability).
color_mode() {
    [ -n "${NO_COLOR:-}" ] && { echo off; return; }
    c="$(printf '%s' "${SDD_STATUSLINE_COLOR:-}" | tr 'A-Z' 'a-z' | tr -d '[:space:]')"
    case "$c" in
        off|none|0)          echo off;       return ;;
        256|8bit|ansi256)    echo 256;       return ;;
        truecolor|24bit|rgb) echo truecolor; return ;;
    esac
    case "$(printf '%s' "${COLORTERM:-}" | tr 'A-Z' 'a-z')" in
        truecolor|24bit) echo truecolor; return ;;
    esac
    echo truecolor
}
COLOR_MODE="$(color_mode)"
ESC="$(printf '\033')"
to256() {  # $1=r $2=g $3=b → índice xterm-256 (cubo 6×6×6 + rampa de cinzas)
    awk -v r="$1" -v g="$2" -v b="$3" 'BEGIN{
        if (r==g && g==b) {
            if (r<8)   { print 16;  exit }
            if (r>248) { print 231; exit }
            printf "%d", int((r-8)/247*24+0.5)+232; exit
        }
        printf "%d", 16 + 36*int(r/255*5+0.5) + 6*int(g/255*5+0.5) + int(b/255*5+0.5)
    }'
}
paint() {  # $1=cor "R;G;B"  $2=texto  $3=modo(bold|dim|'')
    [ "$COLOR_MODE" = off ] && { printf '%s' "$2"; return; }
    pre=""; case "${3:-}" in bold) pre="1;" ;; dim) pre="2;" ;; esac
    if [ "$COLOR_MODE" = 256 ]; then
        IFS=';' read -r r g b <<< "$1"
        printf '%s[%s38;5;%sm%s%s[0m' "$ESC" "$pre" "$(to256 "$r" "$g" "$b")" "$2" "$ESC"
        return
    fi
    printf '%s[%s38;2;%sm%s%s[0m' "$ESC" "$pre" "$1" "$2" "$ESC"
}
level_color() {  # $1 = pct inteiro → ecoa a cor da faixa
    if   [ "$1" -ge "$TH_HIGH" ]; then printf '%s' "$C_danger"
    elif [ "$1" -ge "$TH_MID" ];  then printf '%s' "$C_caution"
    elif [ "$1" -ge "$TH_LOW" ];  then printf '%s' "$C_warning"
    else printf '%s' "$C_success"; fi
}
SEP="$(paint "$C_muted" "  ·  ")"

# --- helpers de formato (awk: sem depender de libs) -----------------------
fmt_tokens() { awk -v n="$1" 'BEGIN{ if(n>=1000000)printf"%.1fM",n/1000000; else if(n>=1000)printf"%.0fk",n/1000; else printf"%d",n }'; }
fmt_size()   { awk -v n="$1" 'BEGIN{ if(n>=900000)printf"1M"; else if(n>=150000)printf"200k"; else if(n>=1000)printf"%.0fk",n/1000; else printf"%d",n }'; }
fmt_dur()    { awk -v ms="$1" 'BEGIN{ s=int(ms/1000); m=int(s/60); c=s%60; if(m>0)printf"%dm%ds",m,c; else printf"%ds",c }'; }
round()      { awk -v x="$1" 'BEGIN{ printf"%d", (x+0.5) }'; }
fmt_reset()  { awk -v s="$1" 'BEGIN{ if(s<0)s=0;
                 if(s>=86400) printf"%dd", int(s/86400);
                 else if(s>=3600) printf"%dh", int(s/3600);
                 else printf"%dm", int(s/60) }'; }
render_minibar() {  # $1=pct → micro-barra 4 blocos (▰ preenchido cor da faixa, ▱ vazio track)
    f="$(awk -v p="$1" 'BEGIN{f=int(4*p/100+0.5); if(f<0)f=0; if(f>4)f=4; print f}')"
    fs=""; es=""; i=0
    while [ "$i" -lt "$f" ]; do fs="$fs▰"; i=$((i+1)); done
    while [ "$i" -lt 4 ];    do es="$es▱"; i=$((i+1)); done
    printf '%s%s' "$(paint "$(level_color "$1")" "$fs")" "$(paint "$C_track" "$es")"
}
render_rate() {  # $1=label $2=pct $3=reset_epoch $4=withreset(1/0)
    seg="$(paint "$C_accent" "$1" bold) $(render_minibar "$2") $(paint "$(level_color "$2")" "$(round "$2")%")"
    if [ "$4" = 1 ] && [ -n "$3" ]; then
        delta=$(( ${3%.*} - now ))
        [ "$delta" -gt 0 ] && seg="$seg $(paint "$C_muted" "$(fmt_reset "$delta")")"
    fi
    printf '%s' "$seg"
}

# --- extrai campos (uma passada jq) ---------------------------------------
# Separador US (\x1f), não-whitespace: `read` preserva campos vazios do meio (sem `workspace`/
# `version`/`rate_limits`). Com \t o `read` colapsa tabs consecutivos e desalinha os campos.
IFS="$(printf '\037')" read -r model cwd projdir version ctxsize usedpct cost durms rate5 rate7 reset5 reset7 <<EOF
$(printf '%s' "$input" | jq -r '
  [ (.model.display_name // .model.id // "?"),
    (.workspace.current_dir // .cwd // ""),
    (.workspace.project_dir // .workspace.current_dir // .cwd // ""),
    (.version // ""),
    (.context_window.context_window_size // 200000),
    (.context_window.used_percentage // ""),
    (.cost.total_cost_usd // 0),
    (.cost.total_duration_ms // 0),
    (.rate_limits.five_hour.used_percentage // ""),
    (.rate_limits.seven_day.used_percentage // ""),
    (.rate_limits.five_hour.resets_at // ""),
    (.rate_limits.seven_day.resets_at // "")
  ] | map(tostring) | join("")')
EOF
now="$(date +%s)"

[ -z "$cwd" ] && cwd="$PWD"
[ -z "$projdir" ] && projdir="$cwd"
dir="$(basename "$cwd")"

if [ -n "$usedpct" ]; then ctx_known=1; used_int="$(round "$usedpct")"; else ctx_known=0; used_int=0; fi
ctx_tokens="$(awk -v s="$ctxsize" -v u="$used_int" 'BEGIN{printf"%d", (s*u/100)+0.5}')"

# --- git (lock-free, resiliente) -----------------------------------------
branch=""; staged=0; modified=0; untracked=0
gitroot=""
if [ -e "$cwd/.git" ]; then gitroot="$cwd"; elif [ -e "$projdir/.git" ]; then gitroot="$projdir"; fi
if [ -n "$gitroot" ]; then
    branch="$(git -C "$gitroot" --no-optional-locks symbolic-ref --short HEAD 2>/dev/null)"
    if [ -z "$branch" ]; then
        sha="$(git -C "$gitroot" --no-optional-locks rev-parse --short HEAD 2>/dev/null)"
        [ -n "$sha" ] && branch="detached:$sha"
    fi
    staged="$(git -C "$gitroot" --no-optional-locks diff --cached --name-only 2>/dev/null | grep -c '' )"
    modified="$(git -C "$gitroot" --no-optional-locks diff --name-only 2>/dev/null | grep -c '' )"
    untracked="$(git -C "$gitroot" --no-optional-locks ls-files --others --exclude-standard 2>/dev/null | grep -c '' )"
fi

# ═══════════════ LINHA 1: modelo · git · dir · versão ═══════════════
l1=" $(paint "$C_primary" "$model" bold)"
if [ -n "$branch" ]; then
    l1="$l1$SEP$(paint "$C_warning" "⎇ $branch")"
    [ "$staged" -gt 0 ]    && l1="$l1 $(paint "$C_success" "+$staged")"
    [ "$modified" -gt 0 ]  && l1="$l1 $(paint "$C_caution" "~$modified")"
    [ "$untracked" -gt 0 ] && l1="$l1 $(paint "$C_muted" "?$untracked")"
fi
l1="$l1$SEP$(paint "$C_accent" "$dir")"
[ -n "$version" ] && l1="$l1$SEP$(paint "$C_muted" "v$version")"

# ═══════════════ LINHA 2: barra ctx · % · tokens · rates · tempo · custo ═══════════════
barwidth=14
filled="$(awk -v w="$barwidth" -v u="$used_int" 'BEGIN{f=int(w*u/100+0.5); if(f<0)f=0; if(f>w)f=w; print f}')"
barcolor="$(level_color "$used_int")"
# Vazio: ░ sem cor (NO_COLOR, p/ distinguir do preenchido) ou █ com cor track nos modos coloridos.
if [ "$COLOR_MODE" = off ]; then emptych='░'; else emptych='█'; fi
fstr=""; estr=""; i=0
while [ "$i" -lt "$filled" ];   do fstr="$fstr█"; i=$((i+1)); done
while [ "$i" -lt "$barwidth" ]; do estr="$estr$emptych"; i=$((i+1)); done
bar="$(paint "$barcolor" "$fstr")$(paint "$C_track" "$estr")"

if [ "$ctx_known" -eq 1 ]; then pctstr="$(paint "$barcolor" "${used_int}%")"; else pctstr="$(paint "$C_muted" "--")"; fi
l2=" $bar $pctstr $(paint "$C_muted" "$(fmt_tokens "$ctx_tokens")/$(fmt_size "$ctxsize")")"

# rates: mini-barra + % por janela (5h/7d); reset ⟳ só na de MAIOR uso. Degrada se ausente.
ratestr=""
dom5=0
if [ -n "$rate5" ]; then
    if [ -z "$rate7" ] || awk -v a="$rate5" -v b="$rate7" 'BEGIN{exit !(a>=b)}'; then dom5=1; fi
    ratestr="$(render_rate 5h "$rate5" "$reset5" "$dom5")"
fi
if [ -n "$rate7" ]; then
    dom7=1; [ "$dom5" = 1 ] && dom7=0
    seg7="$(render_rate 7d "$rate7" "$reset7" "$dom7")"
    if [ -n "$ratestr" ]; then ratestr="$ratestr $(paint "$C_muted" "·") $seg7"; else ratestr="$seg7"; fi
fi
[ -n "$ratestr" ] && l2="$l2$SEP$ratestr"

l2="$l2$SEP$(paint "$C_primary" "⏱ $(fmt_dur "$durms")")"
awk -v c="$cost" 'BEGIN{exit !(c>0)}' && l2="$l2$SEP$(paint "$C_success" "$(awk -v c="$cost" 'BEGIN{printf"$%.2f",c}')")"

printf '%s\n%s' "$l1" "$l2"
