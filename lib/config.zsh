# quickmenu :: config file loading
#
# Three formats are understood, picked by file extension:
#
#   menu.conf  - simple INI-ish text (the default; no dependencies)
#   menu.json  - JSON, read with jq or python3
#   menu.zsh   - zsh script calling qm_item, for anything dynamic
#
# The .conf format:
#
#   [group]                     # optional section; becomes the group name
#   .if = <shell condition>     # before any item: applies to the whole section
#
#   Label = command             # an item
#   .desc    = extra keywords   # after an item: applies to that item
#   .confirm = yes
#
# Lines ending in \ continue on the next line. Comments are whole lines
# starting with # or ;.

_qm_truthy() {
  [[ ${(L)1} == (yes|y|true|t|on|1) ]]
}

_qm_conf_unquote() {
  local s=$1
  if [[ ${#s} -ge 2 && ( ( $s == \"*\" ) || ( $s == \'*\' ) ) ]]; then
    s=${s[2,-2]}
  fi
  print -r -- "$s"
}

_qm_add_parsed() {
  # label cmd group desc cond flags
  local flags=''
  [[ $6 == *y* ]] && flags+='y'
  [[ $6 == *e* ]] && flags+='e'
  _QM_LABEL+=( "$1" )
  _QM_CMD+=( "$2" )
  _QM_GROUP+=( "$3" )
  _QM_DESC+=( "$4" )
  _QM_COND+=( "$5" )
  _QM_FLAGS+=( "$flags" )
}

# --- INI-ish parser ----------------------------------------------------------

_qm_parse_conf() {
  emulate -L zsh
  setopt local_options extended_glob

  local file=$1
  local raw line key val cont='' mod
  local -i lineno=0 have=0
  local sec_group='' sec_if='' sec_desc='' sec_flags=''
  local it_label='' it_cmd='' it_if='' it_desc='' it_group='' it_flags=''

  _qm_conf_flush() {
    (( have )) || return 0
    local g=${it_group:-$sec_group}
    local d=${it_desc:-$sec_desc}
    local c
    if [[ -n $sec_if && -n $it_if ]]; then
      c="{ ${sec_if} } && { ${it_if} }"
    elif [[ -n $it_if ]]; then
      c=$it_if
    else
      c=$sec_if
    fi
    _qm_add_parsed "$it_label" "$it_cmd" "$g" "$d" "$c" "${sec_flags}${it_flags}"
    have=0
    it_label=''; it_cmd=''; it_if=''; it_desc=''; it_group=''; it_flags=''
  }

  {
    while IFS= read -r raw || [[ -n $raw ]]; do
      (( lineno++ ))
      line=${${raw##[[:space:]]##}%%[[:space:]]##}

      if [[ -z $cont ]]; then
        [[ -z $line ]] && continue
        [[ $line == ('#'|';')* ]] && continue
      fi

      if [[ $line == *'\' ]]; then
        local piece=${line%'\'}
        cont+="${piece%%[[:space:]]##} "
        continue
      fi
      line="${cont}${line}"
      cont=''

      if [[ $line == '['*']' ]]; then
        _qm_conf_flush
        sec_group=${${${line[2,-2]}##[[:space:]]##}%%[[:space:]]##}
        sec_if=''; sec_desc=''; sec_flags=''
        continue
      fi

      if [[ $line != *=* ]]; then
        print -ru2 -- "quickmenu: ${file}:${lineno}: expected 'Label = command'"
        continue
      fi

      key=${${${line%%=*}##[[:space:]]##}%%[[:space:]]##}
      val=${${${line#*=}##[[:space:]]##}%%[[:space:]]##}
      val=$(_qm_conf_unquote "$val")

      if [[ $key == '.'* ]]; then
        mod=${(L)key#.}
        if (( have )); then
          case $mod in
            if|cond|condition) it_if=$val ;;
            desc|description)  it_desc=$val ;;
            group)             it_group=$val ;;
            confirm)           _qm_truthy "$val" && it_flags+='y' ;;
            edit)              _qm_truthy "$val" && it_flags+='e' ;;
            *) print -ru2 -- "quickmenu: ${file}:${lineno}: unknown setting '.${mod}'" ;;
          esac
        else
          case $mod in
            if|cond|condition) sec_if=$val ;;
            desc|description)  sec_desc=$val ;;
            group)             sec_group=$val ;;
            confirm)           _qm_truthy "$val" && sec_flags+='y' ;;
            edit)              _qm_truthy "$val" && sec_flags+='e' ;;
            *) print -ru2 -- "quickmenu: ${file}:${lineno}: unknown setting '.${mod}'" ;;
          esac
        fi
        continue
      fi

      _qm_conf_flush
      it_label=$(_qm_conf_unquote "$key")
      it_cmd=$val
      have=1

      if [[ -z $it_label || -z $it_cmd ]]; then
        print -ru2 -- "quickmenu: ${file}:${lineno}: item needs both a label and a command"
        have=0
      fi
    done < "$file"
    _qm_conf_flush
  } always {
    unfunction _qm_conf_flush 2>/dev/null
  }

  return 0
}

# --- JSON --------------------------------------------------------------------

# Accepts either [ {...}, {...} ] or { "items": [ {...} ] }.
# Each object: label/name, run/command/cmd, group, desc/description,
#              if/condition, confirm, edit.
_qm_json_to_stream() {
  local file=$1

  if (( ${+commands[jq]} )); then
    command jq -j -r '
      (if type == "array" then . elif has("items") then .items else [.] end)[]
      | ( (.label // .name // ""),         "\u001f",
          (.run // .command // .cmd // ""), "\u001f",
          (.group // ""),                   "\u001f",
          (.desc // .description // ""),    "\u001f",
          (.if // .condition // ""),        "\u001f",
          ( (if (.confirm // false) then "y" else "" end)
          + (if (.edit    // false) then "e" else "" end) ), "\u001f" )
    ' -- "$file" && return 0
    return 1
  fi

  if (( ${+commands[python3]} )); then
    command python3 - "$file" <<'PY' && return 0
import json, sys
with open(sys.argv[1]) as fh:
    data = json.load(fh)
if isinstance(data, dict):
    data = data.get("items", [data])
out = []
for it in data:
    if not isinstance(it, dict):
        continue
    flags = ("y" if it.get("confirm") else "") + ("e" if it.get("edit") else "")
    out += [
        str(it.get("label", it.get("name", ""))),
        str(it.get("run", it.get("command", it.get("cmd", "")))),
        str(it.get("group", "")),
        str(it.get("desc", it.get("description", ""))),
        str(it.get("if", it.get("condition", ""))),
        flags,
    ]
sys.stdout.write("".join(f + "\x1f" for f in out))
PY
    return 1
  fi

  print -ru2 -- "quickmenu: reading ${file} needs jq or python3"
  return 1
}

_qm_parse_json() {
  emulate -L zsh
  local file=$1 stream
  stream=$(_qm_json_to_stream "$file" 2>&1) || {
    print -ru2 -- "quickmenu: could not read ${file}"
    [[ -n $stream ]] && print -ru2 -- "  ${stream%%$'\n'*}"
    return 1
  }

  local label cmd group desc cond flags
  local -i n=0
  while IFS= read -r -d $'\x1f' label; do
    IFS= read -r -d $'\x1f' cmd   || break
    IFS= read -r -d $'\x1f' group || break
    IFS= read -r -d $'\x1f' desc  || break
    IFS= read -r -d $'\x1f' cond  || break
    IFS= read -r -d $'\x1f' flags || break
    if [[ -z $label || -z $cmd ]]; then
      print -ru2 -- "quickmenu: ${file}: item ${n} needs both a label and a command"
      (( n++ ))
      continue
    fi
    _qm_add_parsed "$label" "$cmd" "$group" "$desc" "$cond" "$flags"
    (( n++ ))
  done <<< "$stream"
  return 0
}

# --- dispatch ----------------------------------------------------------------

# Load one config file, choosing a parser from its extension.
_qm_load_file() {
  emulate -L zsh
  local f=$1
  _qm_check_file "$f" || return 1
  case ${(L)f:e} in
    json)      _qm_parse_json "$f" ;;
    zsh|sh)    _qm_source_file "$f" ;;
    conf|ini|menu|'') _qm_parse_conf "$f" ;;
    *)         _qm_parse_conf "$f" ;;
  esac
}

# --- writing -----------------------------------------------------------------

# Append an item to the primary .conf file.
_qm_conf_append() {
  emulate -L zsh
  local file=$1 label=$2 cmd=$3 group=$4
  local -a lines

  if [[ $label == *=* ]]; then
    print -ru2 -- "quickmenu: a label cannot contain '='"
    return 1
  fi

  command mkdir -p "${file:h}" 2>/dev/null
  [[ -s $file ]] && lines+=( '' )
  lines+=( "${label} = ${cmd}" )
  [[ -n $group ]] && lines+=( ".group = ${group}" )

  print -rl -- "${lines[@]}" >> "$file" || return 1
  return 0
}
