# quickmenu :: placeholder resolution
#
# Commands may embed placeholders that are filled in at launch time:
#
#   {{prompt:Label}}              ask for free text
#   {{prompt:Label=default}}      ask, pre-filled with a default
#   {{pick:shell command}}        run the command, pick one of its output lines
#   {{file:*.xcodeproj *.xcworkspace}}  pick a matching file/dir in $PWD
#   {{dir}}                       pick a sub-directory of $PWD
#
# Values are shell-quoted before substitution. Add a "!" to the keyword
# ({{prompt!:Flags}}) to insert the raw text instead, e.g. for extra flags.

_qm_read_line() {
  emulate -L zsh
  local label=$1 def=$2
  local tty_out=${QUICKMENU_TTY_OUT:-/dev/tty}
  local tty_in=${QUICKMENU_TTY_IN:-/dev/tty}

  if [[ -r $tty_in && -w $tty_out ]]; then
    local prompt="${label}"
    [[ -n $def ]] && prompt+=" [${def}]"
    prompt+=": "
    print -rn -- "$prompt" > $tty_out
    IFS= read -r REPLY < $tty_in || return 1
  else
    print -rn -ru2 -- "${label}${def:+ [$def]}: "
    IFS= read -r REPLY || return 1
  fi

  [[ -z $REPLY ]] && REPLY=$def
  return 0
}

_qm_confirm() {
  emulate -L zsh
  local msg=$1 ans
  local tty_out=${QUICKMENU_TTY_OUT:-/dev/tty}
  local tty_in=${QUICKMENU_TTY_IN:-/dev/tty}
  if [[ -r $tty_in && -w $tty_out ]]; then
    print -rn -- "${msg} [y/N] " > $tty_out
    IFS= read -r ans < $tty_in || return 1
  else
    print -rn -ru2 -- "${msg} [y/N] "
    IFS= read -r ans || return 1
  fi
  [[ ${(L)ans} == y* ]]
}

# _qm_resolve_token <token> -> REPLY
_qm_resolve_token() {
  emulate -L zsh
  setopt local_options null_glob

  local token=$1
  local kind=${token%%:*}
  local arg=''
  [[ $token == *:* ]] && arg=${token#*:}

  local -i raw=0
  if [[ $kind == *'!' ]]; then
    raw=1
    kind=${kind%!}
  fi

  local value=''

  case $kind in
    prompt|input|ask)
      local label=$arg def=''
      if [[ $arg == *=* ]]; then
        label=${arg%%=*}
        def=${arg#*=}
      fi
      _qm_read_line "${label:-value}" "$def" || return 1
      value=$REPLY
      ;;

    pick|choose)
      local -a lines
      lines=( ${(f)"$(eval "$arg" 2>/dev/null)"} )
      lines=( ${lines:#} )
      if (( ! $#lines )); then
        print -ru2 -- "quickmenu: nothing to pick for '{{${token}}}'"
        return 1
      fi
      if (( $#lines == 1 )); then
        value=${lines[1]}
      else
        local -a _qm_tmp_labels=( "${lines[@]}" )
        _qm_pick "select" _qm_tmp_labels || return 1
        value=${lines[REPLY]}
      fi
      ;;

    file|files)
      local -a pats matches
      pats=( ${(z)arg} )
      (( $#pats )) || pats=( '*' )
      local p
      for p in "${pats[@]}"; do
        matches+=( ${~p}(N) )
      done
      if (( ! $#matches )); then
        print -ru2 -- "quickmenu: no files matching '${arg}' in ${PWD}"
        return 1
      fi
      if (( $#matches == 1 )); then
        value=${matches[1]}
      else
        local -a _qm_tmp_labels=( "${matches[@]}" )
        _qm_pick "select file" _qm_tmp_labels || return 1
        value=${matches[REPLY]}
      fi
      ;;

    dir|dirs)
      local -a dirs=( ${~${arg:-*}}(N/) )
      if (( ! $#dirs )); then
        print -ru2 -- "quickmenu: no directories matching '${arg:-*}' in ${PWD}"
        return 1
      fi
      local -a _qm_tmp_labels=( "${dirs[@]}" )
      _qm_pick "select directory" _qm_tmp_labels || return 1
      value=${dirs[REPLY]}
      ;;

    env)
      value=${(P)arg}
      ;;

    *)
      print -ru2 -- "quickmenu: unknown placeholder '{{${token}}}'"
      return 1
      ;;
  esac

  if (( raw )); then
    REPLY=$value
  else
    REPLY=${(q)value}
  fi
  return 0
}

# _qm_resolve <command> -> REPLY (command with placeholders filled in)
_qm_resolve() {
  emulate -L zsh
  local rest=$1 out='' before token

  while [[ $rest == *'{{'*'}}'* ]]; do
    before=${rest%%\{\{*}
    rest=${rest#*\{\{}
    token=${rest%%\}\}*}
    rest=${rest#*\}\}}
    _qm_resolve_token "$token" || return 1
    out+="${before}${REPLY}"
  done

  REPLY="${out}${rest}"
  return 0
}
