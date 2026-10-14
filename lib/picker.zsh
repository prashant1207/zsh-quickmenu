# quickmenu :: picker
# A dependency-free interactive list picker for zsh, with optional fzf backend.
#
#   _qm_pick <header> <labels-array-name> [<subtitles-array-name>]
#
# On success sets:
#   REPLY            -> 1-based index of the chosen entry
#   _qm_pick_action  -> "run" (Enter) or "edit" (Tab)
# Returns non-zero when the user cancels.

# --- small helpers -----------------------------------------------------------

# Glyphs the current locale can actually render.
_qm_glyphs() {
  typeset -g _QM_G_PROMPT _QM_G_CARET _QM_G_ELLIPSIS
  local enc=${LC_ALL:-${LC_CTYPE:-${LANG:-}}}
  if [[ ${(L)enc} == *utf*8* ]]; then
    _QM_G_PROMPT=$'\u276f '
    _QM_G_CARET=$'\u258f'
    _QM_G_ELLIPSIS=$'\u2026'
  else
    _QM_G_PROMPT='> '
    _QM_G_CARET='_'
    _QM_G_ELLIPSIS='..'
  fi
}
_qm_glyphs

_qm_cols() {
  local -i c=${COLUMNS:-0}
  (( c > 0 )) || c=$(command tput cols 2>/dev/null) || c=0
  (( c > 0 )) || c=80
  print -r -- $c
}

_qm_lines() {
  local -i l=${LINES:-0}
  (( l > 0 )) || l=$(command tput lines 2>/dev/null) || l=0
  (( l > 0 )) || l=24
  print -r -- $l
}

# Case-insensitive subsequence match: does every char of $1 appear in order in $2?
_qm_subseq() {
  local q=${(L)1} s=${(L)2}
  local -i qi=1 si=1 ql=${#q} sl=${#s}
  local qc
  while (( qi <= ql )); do
    qc=${q[qi]}
    if [[ $qc == ' ' ]]; then (( qi++ )); continue; fi
    while (( si <= sl )) && [[ ${s[si]} != "$qc" ]]; do (( si++ )); done
    (( si <= sl )) || return 1
    (( si++, qi++ ))
  done
  return 0
}

# Truncate $1 to $2 display columns.
_qm_trunc() {
  local s=$1
  local -i w=$2
  local e=${_QM_G_ELLIPSIS:-..}
  if (( w <= 0 )); then
    print -r -- ''
  elif (( ${#s} > w )); then
    if (( w > ${#e} )); then
      print -r -- "${s[1,w-${#e}]}${e}"
    else
      print -r -- "${s[1,w]}"
    fi
  else
    print -r -- "$s"
  fi
}

# Read one keypress from fd $1, normalising escape sequences.
# Sets REPLY to a key name ("up", "down", "enter", "tab", "escape", "backspace",
# "pgup", "pgdn", "home", "end", "ignore", "cancel", "clear", "wordback")
# or to the literal character typed.
_qm_read_key() {
  local -i fd=$1
  local k k2 k3 k4
  IFS= read -r -s -k 1 -u $fd k || return 1

  case $k in
    $'\e')
      if IFS= read -r -s -k 1 -t 0.06 -u $fd k2; then
        case $k2 in
          '['|'O')
            IFS= read -r -s -k 1 -t 0.06 -u $fd k3 || { REPLY=escape; return 0; }
            case $k3 in
              A) REPLY=up ;;
              B) REPLY=down ;;
              C) REPLY=right ;;
              D) REPLY=left ;;
              H) REPLY=home ;;
              F) REPLY=end ;;
              Z) REPLY=btab ;;
              <0-9>)
                while IFS= read -r -s -k 1 -t 0.06 -u $fd k4; do
                  [[ $k4 == '~' ]] && break
                  k3+=$k4
                done
                case $k3 in
                  5) REPLY=pgup ;;
                  6) REPLY=pgdn ;;
                  1|7) REPLY=home ;;
                  4|8) REPLY=end ;;
                  *) REPLY=ignore ;;
                esac
                ;;
              *) REPLY=ignore ;;
            esac
            ;;
          *) REPLY=escape ;;
        esac
      else
        REPLY=escape
      fi
      ;;
    $'\n'|$'\r')   REPLY=enter ;;
    $'\t')         REPLY=tab ;;
    $'\177'|$'\b') REPLY=backspace ;;
    $'\003')       REPLY=cancel ;;    # Ctrl-C
    $'\004')       REPLY=cancel ;;    # Ctrl-D
    $'\007')       REPLY=cancel ;;    # Ctrl-G
    $'\016')       REPLY=down ;;      # Ctrl-N
    $'\020')       REPLY=up ;;        # Ctrl-P
    $'\025')       REPLY=clear ;;     # Ctrl-U
    $'\027')       REPLY=wordback ;;  # Ctrl-W
    *)             REPLY=$k ;;
  esac
  return 0
}

# --- fzf backend -------------------------------------------------------------

_qm_pick_fzf() {
  local header=$1 larr=$2 sarr=$3
  local -a labels subs
  labels=( "${(@P)larr}" )
  [[ -n $sarr ]] && subs=( "${(@P)sarr}" )

  local -a feed
  local -i i
  for (( i = 1; i <= $#labels; i++ )); do
    feed+=( "${i}"$'\t'"${labels[i]}"$'\t'"${subs[i]//$'\n'/ ; }" )
  done

  local out
  out=$(print -rl -- "${feed[@]}" | command fzf \
        --ansi --no-sort --exit-0 \
        --delimiter=$'\t' --with-nth=2.. \
        --height="${QUICKMENU_HEIGHT:-14}" --layout=reverse --border \
        --prompt="${QUICKMENU_PROMPT:-$_QM_G_PROMPT}" \
        --header="$header" \
        --expect=tab,enter 2>/dev/null) || return 1

  local key=${out%%$'\n'*}
  local line=${out#*$'\n'}
  [[ -n $line ]] || return 1
  REPLY=${line%%$'\t'*}
  [[ $REPLY == <-> ]] || return 1
  if [[ $key == tab ]]; then _qm_pick_action=edit; else _qm_pick_action=run; fi
  return 0
}

# --- plain numbered fallback (no tty / dumb terminal) ------------------------

_qm_pick_dumb() {
  local header=$1 larr=$2 sarr=$3
  local -a labels subs
  labels=( "${(@P)larr}" )
  [[ -n $sarr ]] && subs=( "${(@P)sarr}" )

  print -ru2 -- "$header"
  local -i i
  for (( i = 1; i <= $#labels; i++ )); do
    printf '%3d) %s\n' $i "${labels[i]}" >&2
  done

  local answer
  print -nru2 -- "${QUICKMENU_PROMPT:-$_QM_G_PROMPT}"
  IFS= read -r answer || return 1
  [[ -n $answer ]] || return 1

  if [[ $answer == <-> ]] && (( answer >= 1 && answer <= $#labels )); then
    REPLY=$answer
    _qm_pick_action=run
    return 0
  fi

  for (( i = 1; i <= $#labels; i++ )); do
    if [[ ${(L)labels[i]} == *${(L)answer}* ]] || _qm_subseq "$answer" "${labels[i]} ${subs[i]}"; then
      REPLY=$i
      _qm_pick_action=run
      return 0
    fi
  done
  return 1
}

# --- native TUI --------------------------------------------------------------

_qm_pick_tui() {
  emulate -L zsh
  setopt local_options no_bang_hist

  local header=$1 larr=$2 sarr=$3
  local -a labels subs
  labels=( "${(@P)larr}" )
  if [[ -n $sarr ]]; then subs=( "${(@P)sarr}" ); else subs=(); fi
  (( $#labels )) || return 1

  local tty_in=${QUICKMENU_TTY_IN:-/dev/tty}
  local tty_out=${QUICKMENU_TTY_OUT:-/dev/tty}
  local -i ifd ofd
  # NB: the redirection must be scoped to the braces - `exec ... 2>/dev/null`
  # would silence the calling shell's stderr for good.
  { exec {ifd}<$tty_in } 2>/dev/null || return 2
  { exec {ofd}>$tty_out } 2>/dev/null || { exec {ifd}<&- ; return 2 }

  local saved_stty=''
  local -i interactive=0
  if [[ -t $ifd ]]; then
    saved_stty=$(command stty -g <&$ifd 2>/dev/null)
    if [[ -n $saved_stty ]]; then
      interactive=1
    else
      # A real terminal we can't put into raw mode: single keypresses would
      # never arrive. Let the caller use the numbered picker instead.
      exec {ifd}<&-
      exec {ofd}>&-
      return 2
    fi
  fi

  local reset='' inv='' dim='' kcol='' hdr='' bold=''
  if [[ -z ${QUICKMENU_NO_COLOR:-} ]]; then
    reset=$'\e[0m'; inv=$'\e[7m'; dim=$'\e[2m'; kcol=$'\e[36m'; hdr=$'\e[1;35m'; bold=$'\e[1m'
  fi

  local -i cursor=1 offset=1 drawn=0 rc=1
  local query=''
  local -a view
  local -i cols term_lines
  cols=$(_qm_cols)
  term_lines=$(_qm_lines)

  _qm_pick_filter() {
    view=()
    local -i i
    if [[ -z $query ]]; then
      for (( i = 1; i <= $#labels; i++ )); do view+=( $i ); done
      return
    fi
    # Label substring matches first, then anything the query fuzzy-matches.
    local q=${(L)query} hay lab
    local -a strong weak
    for (( i = 1; i <= $#labels; i++ )); do
      lab=${(L)labels[i]}
      hay="${lab} ${(L)subs[i]}"
      if [[ $lab == *$q* ]]; then
        strong+=( $i )
      elif [[ $hay == *$q* ]] || _qm_subseq "$q" "$hay"; then
        weak+=( $i )
      fi
    done
    view=( $strong $weak )
  }

  _qm_pick_draw() {
    local -a out
    local -i maxh=${QUICKMENU_HEIGHT:-12}
    local -i room=$(( term_lines - 4 ))
    (( maxh > room )) && maxh=$room
    (( maxh < 3 )) && maxh=3

    local -i vn=$#view
    local -i h=$(( vn < maxh ? vn : maxh ))
    (( h < 0 )) && h=0

    (( cursor < 1 )) && cursor=1
    (( cursor > vn )) && cursor=$vn
    (( cursor < offset )) && offset=$cursor
    (( h > 0 && cursor > offset + h - 1 )) && offset=$(( cursor - h + 1 ))
    (( offset < 1 )) && offset=1

    out+=( "${hdr}${header}${reset}  ${dim}(${vn}/${#labels})${reset}" )
    out+=( "${bold}${QUICKMENU_PROMPT:-$_QM_G_PROMPT}${reset}${query}${dim}${_QM_G_CARET}${reset}" )

    local -i labelw=0 i
    for (( i = offset; i < offset + h && i <= vn; i++ )); do
      (( ${#labels[view[i]]} > labelw )) && labelw=${#labels[view[i]]}
    done
    (( labelw > cols / 2 )) && labelw=$(( cols / 2 ))

    (( vn == 0 )) && out+=( "  ${dim}no matches${reset}" )

    local lbl sub numtxt mark line
    local -i idx pad used avail fill
    for (( i = offset; i < offset + h && i <= vn; i++ )); do
      idx=${view[i]}
      lbl=$(_qm_trunc "${labels[idx]}" $labelw)
      sub=${subs[idx]//$'\n'/ ; }

      numtxt='  '
      local -i row=$(( i - offset + 1 ))
      if (( row <= 9 )); then
        numtxt="${row} "
      elif (( row == 10 )); then
        numtxt='0 '
      fi
      mark='  '
      (( i == cursor )) && mark='> '

      pad=$(( labelw - ${#lbl} ))
      (( pad < 0 )) && pad=0
      used=$(( ${#mark} + ${#numtxt} + ${#lbl} + pad + 2 ))
      avail=$(( cols - used - 1 ))
      (( avail < 0 )) && avail=0
      sub=$(_qm_trunc "$sub" $avail)
      fill=$(( avail - ${#sub} ))
      (( fill < 0 )) && fill=0

      if (( i == cursor )); then
        line="${inv}${mark}${numtxt}${lbl}${(l:pad:: :)}  ${sub}${(l:fill:: :)}${reset}"
      else
        line="${mark}${kcol}${numtxt}${reset}${lbl}${(l:pad:: :)}  ${dim}${sub}${reset}"
      fi
      out+=( "$line" )
    done

    out+=( "${dim}[up/down] move  [1-9] jump  type to filter  [enter] run  [tab] edit  [esc] cancel${reset}" )

    local esc=''
    (( drawn > 0 )) && esc=$'\e['"${drawn}"$'A'
    print -rn -u $ofd -- "${esc}"$'\e[J'"${(pj:\r\n:)out}"$'\r\n'
    drawn=$#out
  }

  _qm_pick_clear() {
    (( drawn > 0 )) && print -rn -u $ofd -- $'\e['"${drawn}"$'A\e[J'
    drawn=0
  }

  {
    if (( interactive )); then
      command stty raw -echo <&$ifd 2>/dev/null
      print -rn -u $ofd -- $'\e[?25l'
    fi

    _qm_pick_filter
    _qm_pick_draw

    while _qm_read_key $ifd; do
      case $REPLY in
        up)   (( cursor-- )); (( cursor < 1 )) && cursor=$#view ;;
        down) (( cursor++ )); (( cursor > $#view )) && cursor=1 ;;
        pgup) (( cursor -= ${QUICKMENU_HEIGHT:-12} )); (( cursor < 1 )) && cursor=1 ;;
        pgdn) (( cursor += ${QUICKMENU_HEIGHT:-12} )); (( cursor > $#view )) && cursor=$#view ;;
        home) cursor=1 ;;
        end)  cursor=$#view ;;
        enter|right)
          (( $#view )) || { _qm_pick_draw; continue }
          REPLY=${view[cursor]}
          _qm_pick_action=run
          rc=0
          break
          ;;
        tab)
          (( $#view )) || { _qm_pick_draw; continue }
          REPLY=${view[cursor]}
          _qm_pick_action=edit
          rc=0
          break
          ;;
        escape|cancel) rc=1; break ;;
        backspace)
          if [[ -n $query ]]; then
            query=${query[1,-2]}
            _qm_pick_filter; cursor=1; offset=1
          fi
          ;;
        clear)
          query=''; _qm_pick_filter; cursor=1; offset=1
          ;;
        wordback)
          if [[ $query == *' '* ]]; then query=${query% *}; else query=''; fi
          _qm_pick_filter; cursor=1; offset=1
          ;;
        ignore|left|btab) ;;
        <0-9>)
          if [[ -z $query ]]; then
            local -i row=$REPLY
            (( row == 0 )) && row=10
            local -i target=$(( offset + row - 1 ))
            if (( target >= 1 && target <= $#view )); then
              REPLY=${view[target]}
              _qm_pick_action=run
              rc=0
              break
            fi
          else
            query+=$REPLY; _qm_pick_filter; cursor=1; offset=1
          fi
          ;;
        *)
          if [[ ${#REPLY} -eq 1 && $REPLY == [[:print:]] ]]; then
            query+=$REPLY
            _qm_pick_filter; cursor=1; offset=1
          fi
          ;;
      esac
      _qm_pick_draw
    done
  } always {
    _qm_pick_clear
    (( interactive )) && print -rn -u $ofd -- $'\e[?25h'
    [[ -n $saved_stty ]] && command stty "$saved_stty" <&$ifd 2>/dev/null
    exec {ifd}<&-
    exec {ofd}>&-
    unfunction _qm_pick_filter _qm_pick_draw _qm_pick_clear 2>/dev/null
  }

  return $rc
}

# --- dispatcher --------------------------------------------------------------

_qm_pick() {
  typeset -g _qm_pick_action=run
  local header=$1 larr=$2 sarr=${3:-}
  local backend=${QUICKMENU_PICKER:-auto}

  if [[ $backend == auto ]]; then
    if (( ${+commands[fzf]} )) && [[ -n ${QUICKMENU_USE_FZF:-} ]]; then
      backend=fzf
    elif [[ ${TERM:-dumb} == dumb ]]; then
      backend=dumb
    else
      backend=tui
    fi
  fi

  case $backend in
    fzf)  _qm_pick_fzf "$header" "$larr" "$sarr"; return $? ;;
    dumb) _qm_pick_dumb "$header" "$larr" "$sarr"; return $? ;;
  esac

  _qm_pick_tui "$header" "$larr" "$sarr"
  local -i rc=$?
  (( rc == 2 )) && { _qm_pick_dumb "$header" "$larr" "$sarr"; return $? }
  return $rc
}
