#!/usr/bin/env sh
# supplement-hint — ESTÁGIO 1 (POSIX sh, sem pwsh). Registrado direto no settings.json
# (UserPromptSubmit), e NÃO pela dispatch-line J4: lá o .sh é só a degradação sem pwsh, e o gate da
# dispatch-line consome o stdin ao pular — aqui o filtro precisa LER o prompt antes de decidir.
#
# O que faz: lê o stdin, casa a união dos padrões do supplement-hint.triggers (grep -iE) e
#   - não casou                 -> SILÊNCIO (exit 0). É o caso comum, e roda em todo prompt.
#   - casou e há pwsh           -> repassa o stdin ao supplement-hint.ps1 (estágio 2: confirma o tema
#                                  no campo `prompt`, olha o estado do plugin, dedup, emite).
#   - casou e NÃO há pwsh       -> SILÊNCIO. Degradação consciente: o /supplements também exige pwsh.
# O grep roda no JSON cru (pode casar o `cwd`): o falso positivo custa só subir o estágio 2, que
# confere no campo certo. Read-only; nunca bloqueia.
#
# SÓ BUILTINS ATÉ O GREP: no Windows (MSYS) cada processo custa 30-40 ms. A 1ª versão usava
# dirname/cat/tr/grep/cut/paste e gastava ~0,29 s por prompt; com read/while/${} sobra um processo.
# `read` lê UMA linha: o payload do Claude Code é JSON compacto (quebra de linha do prompt vem
# escapada como \n), medido em 2026-10-03.

case "$0" in */*) dir=${0%/*} ;; *) dir=. ;; esac
trig="$dir/supplement-hint.triggers"
cr=$(printf '\r')

IFS= read -r in || [ -n "$in" ] || exit 0
[ -f "$trig" ] || exit 0

re=; pares=
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%"$cr"}
  case "$line" in ''|'#'*) continue ;; esac
  pat=${line#*"	"}
  [ "$pat" = "$line" ] && continue          # sem TAB: linha malformada
  re=${re:+"$re|"}$pat
  pares="$pares$line
"
done < "$trig"
[ -n "$re" ] || exit 0

grep -iqE -- "$re" <<EOF || exit 0
$in
EOF
command -v pwsh >/dev/null 2>&1 || exit 0

# DEDUP AQUI TAMBÉM, não só no .ps1: sem isto, todo prompt com tema já lembrado pagava ~1 s de pwsh
# para sair calado (num projeto de dados, quase todo prompt cita sql). O estado é o JSON compacto que
# o .ps1 grava: {"session_id":"<id>","themes":["design",...]}. Só sobe o pwsh se algum tema casado
# ainda não está lá para esta sessão. Na dúvida (estado ausente, sessão diferente), sobe: fail-open.
st="$dir/../.cache/supplement-hint.json"
sid=
case "$in" in *'"session_id"'*)            # o harness manda JSON compacto; o espaço após o ':' é tolerado
  sid=${in#*\"session_id\"}; sid=${sid#*\"}; sid=${sid%%\"*} ;;
esac
if [ -f "$st" ] && [ -n "$sid" ]; then
  IFS= read -r estado < "$st" || [ -n "$estado" ]
  case "$estado" in
    *"\"session_id\":\"$sid\""*)
      novo=
      while IFS= read -r par; do
        [ -n "$par" ] || continue
        tema=${par%%"	"*}
        case "$estado" in *"\"$tema\""*) continue ;; esac
        if grep -iqE -- "${par#*"	"}" <<EOF
$in
EOF
        then novo=1; break; fi
      done <<EOF
$pares
EOF
      [ -n "$novo" ] || exit 0
      ;;
  esac
fi

printf '%s\n' "$in" | pwsh -NoProfile -File "$dir/supplement-hint.ps1"
exit 0
