# Single-file Oh My Zsh plugin for turning natural language into shell commands
# via OpenRouter's Responses API.

: "${AICMD_MODEL:=z-ai/glm-5-turbo}"
: "${AICMD_API_URL:=https://openrouter.ai/api/v1/responses}"
: "${AICMD_TARGET_SHELL:=auto}"
: "${AICMD_TIMEOUT:=30}"
: "${AICMD_TITLE:=ai-cmd-oh-my-zsh}"
: "${AICMD_INCLUDE_BUFFER:=1}"
: "${AICMD_INCLUDE_ENV_CONTEXT:=1}"
: "${AICMD_ACCEPT_LINE_TRIGGER:=1}"
: "${AICMD_TRIGGER_PREFIX:=##}"

typeset -g __AICMD_COMMAND=""
typeset -g __AICMD_EXPLANATION=""
typeset -g __AICMD_SAFETY=""
typeset -g __AICMD_CLARIFY=""
typeset -g __AICMD_HTTP_STATUS=""
typeset -g __AICMD_HTTP_BODY=""
typeset -g __AICMD_ERROR=""
typeset -g __AICMD_ARG_TARGET_SHELL=""
typeset -g __AICMD_ARG_PROMPT=""

__aicmd_err() {
  print -u2 -- "aicmd: $*"
}

__aicmd_is_truthy() {
  case "${1:l}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

__aicmd_json_escape() {
  emulate -L zsh
  local value="${1-}"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  value=${value//$'\f'/\\f}
  value=${value//$'\b'/\\b}
  print -rn -- "$value"
}

__aicmd_json_unescape() {
  emulate -L zsh
  local raw="${1-}"
  local out=""
  local i=1
  local ch next hex

  while (( i <= ${#raw} )); do
    ch="${raw[i]}"
    if [[ "$ch" != '\' ]]; then
      out+="$ch"
      (( i++ ))
      continue
    fi

    (( i++ ))
    if (( i > ${#raw} )); then
      out+='\'
      break
    fi

    next="${raw[i]}"
    case "$next" in
      '"') out+='"' ;;
      '\') out+='\' ;;
      '/') out+='/' ;;
      b) out+=$'\b' ;;
      f) out+=$'\f' ;;
      n) out+=$'\n' ;;
      r) out+=$'\r' ;;
      t) out+=$'\t' ;;
      u)
        hex="${raw[i+1,i+4]}"
        if [[ "$hex" == [0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f] ]]; then
          out+="\\u$hex"
          (( i += 4 ))
        else
          out+='u'
        fi
        ;;
      *)
        out+="$next"
        ;;
    esac
    (( i++ ))
  done

  print -rn -- "$out"
}

__aicmd_json_extract_after_marker() {
  emulate -L zsh
  local json="${1-}"
  local marker="${2-}"
  local remainder out="" ch
  local escaped=0
  local i=1

  remainder="${json#*$marker}"
  [[ "$remainder" == "$json" ]] && return 1

  while (( i <= ${#remainder} )); do
    ch="${remainder[i]}"
    if (( escaped )); then
      out+="$ch"
      escaped=0
    elif [[ "$ch" == '\' ]]; then
      out+="$ch"
      escaped=1
    elif [[ "$ch" == '"' ]]; then
      print -rn -- "$out"
      return 0
    else
      out+="$ch"
    fi
    (( i++ ))
  done

  return 1
}

__aicmd_extract_output_text() {
  emulate -L zsh
  local body="${1//$'\n'/}"
  body="${body//$'\r'/}"
  local extracted=""

  extracted="$(__aicmd_json_extract_after_marker "$body" '"output_text":"')" || true
  if [[ -z "$extracted" ]]; then
    extracted="$(__aicmd_json_extract_after_marker "$body" '"type":"output_text","text":"')" || true
  fi
  if [[ -z "$extracted" ]]; then
    extracted="$(__aicmd_json_extract_after_marker "$body" '"type":"output_text_delta","delta":"')" || true
  fi
  [[ -n "$extracted" ]] || return 1

  __aicmd_json_unescape "$extracted"
}

__aicmd_extract_error_field() {
  emulate -L zsh
  local body="${1//$'\n'/}"
  body="${body//$'\r'/}"
  local field="$2"

  __aicmd_json_unescape "$(__aicmd_json_extract_after_marker "$body" "\"$field\":\"")"
}

__aicmd_detect_os() {
  command uname -s 2>/dev/null || print -r -- "unknown"
}

__aicmd_detect_shell() {
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    print -r -- "zsh"
  elif [[ -n "${BASH_VERSION:-}" ]]; then
    print -r -- "bash"
  elif [[ -n "${SHELL:-}" ]]; then
    print -r -- "${SHELL:t}"
  else
    print -r -- "unknown"
  fi
}

__aicmd_detect_package_managers() {
  emulate -L zsh
  local -a detected
  local candidate

  for candidate in brew apt-get apt dnf yum pacman apk nix; do
    if command -v "$candidate" >/dev/null 2>&1; then
      detected+=("$candidate")
    fi
  done

  if (( ${#detected[@]} == 0 )); then
    print -r -- "unknown"
  else
    print -r -- "${(j:,:)detected}"
  fi
}

__aicmd_effective_target_shell() {
  emulate -L zsh
  local override="${1:-}"
  local configured="${AICMD_TARGET_SHELL:-auto}"
  local requested="${override:-$configured}"

  case "${requested:l}" in
    auto)
      if [[ -n "${ZSH_VERSION:-}" ]]; then
        print -r -- "zsh"
      elif [[ -n "${BASH_VERSION:-}" ]]; then
        print -r -- "bash"
      else
        print -r -- "$(__aicmd_detect_shell)"
      fi
      ;;
    zsh|bash)
      print -r -- "${requested:l}"
      ;;
    *)
      __aicmd_err "unsupported target shell '$requested' (expected auto, zsh, or bash)"
      return 1
      ;;
  esac
}

__aicmd_extract_trigger_prompt() {
  emulate -L zsh
  setopt localoptions extendedglob

  local buffer_text="${1-}"
  local prefix="${AICMD_TRIGGER_PREFIX:-##}"
  local prefix_len prompt_text

  [[ -n "$prefix" ]] || return 1

  prefix_len=${#prefix}
  (( prefix_len > 0 )) || return 1
  [[ "${buffer_text[1,prefix_len]}" == "$prefix" ]] || return 1

  prompt_text="${buffer_text[prefix_len + 1,-1]}"
  prompt_text="${prompt_text##[[:space:]]#}"
  [[ -n "$prompt_text" ]] || return 1

  REPLY="$prompt_text"
  return 0
}

__aicmd_build_input() {
  emulate -L zsh
  setopt localoptions extendedglob

  local prompt_text="$1"
  local target_shell="$2"
  local os shell_name package_managers cwd buffer_text
  local input=""

  os="$(__aicmd_detect_os)"
  shell_name="$(__aicmd_detect_shell)"
  package_managers="$(__aicmd_detect_package_managers)"
  cwd="$PWD"
  buffer_text=""

  if __aicmd_is_truthy "${AICMD_INCLUDE_BUFFER:-1}" && [[ -n "${BUFFER:-}" ]]; then
    buffer_text="$BUFFER"
  fi

  input+=$'You convert natural-language requests into one shell command.\n'
  input+=$'Return exactly four lines and nothing else:\n'
  input+=$'COMMAND: <single shell command or empty>\n'
  input+=$'EXPLANATION: <single-line explanation>\n'
  input+=$'SAFETY: safe|caution|destructive|clarify\n'
  input+=$'CLARIFY: <single-line question or none>\n'
  input+=$'Rules:\n'
  input+=$'- Output plain text only. No markdown, bullets, or code fences.\n'
  input+=$'- Generate exactly one command. No surrounding prose.\n'
  input+=$'- Use the provided environment context as authoritative.\n'
  input+=$"- Target shell syntax: ${target_shell}.\n"
  input+=$'- Prefer commands that work on the detected OS and package manager.\n'
  input+=$'- Mark file deletion, reset, force, overwrite, or root-impacting actions as destructive.\n'
  input+=$'- If the request is ambiguous or missing required details, leave COMMAND empty and use SAFETY: clarify.\n'
  input+=$"- If no clarification is needed, output 'CLARIFY: none'.\n"

  if __aicmd_is_truthy "${AICMD_INCLUDE_ENV_CONTEXT:-1}"; then
    input+=$'\nEnvironment context:\n'
    input+=$"OS: ${os}\n"
    input+=$"Current shell: ${shell_name}\n"
    input+=$"Target shell: ${target_shell}\n"
    input+=$"Package managers: ${package_managers}\n"
    input+=$"Working directory: ${cwd}\n"
    if [[ -n "$buffer_text" ]]; then
      input+=$"Current prompt buffer: ${buffer_text}\n"
    fi
  fi

  input+=$'\nUser request:\n'
  input+="$prompt_text"

  print -rn -- "$input"
}

__aicmd_call_openrouter() {
  emulate -L zsh
  local prompt_text="$1"
  local target_shell="$2"
  local input_text payload response curl_status
  local -a curl_args

  __AICMD_HTTP_STATUS=""
  __AICMD_HTTP_BODY=""
  __AICMD_ERROR=""

  if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
    __AICMD_ERROR="OPENROUTER_API_KEY is not set"
    return 1
  fi

  input_text="$(__aicmd_build_input "$prompt_text" "$target_shell")"
  payload=$(
    print -rn -- '{'
    print -rn -- '"model":"'"$(__aicmd_json_escape "$AICMD_MODEL")"'",'
    print -rn -- '"input":"'"$(__aicmd_json_escape "$input_text")"'",'
    print -rn -- '"max_output_tokens":220,'
    print -rn -- '"temperature":0.1'
    print -rn -- '}'
  )

  curl_args=(
    -sS
    --max-time "$AICMD_TIMEOUT"
    -X POST "$AICMD_API_URL"
    -H "Authorization: Bearer $OPENROUTER_API_KEY"
    -H "Content-Type: application/json"
    -H "Accept: application/json"
    -H "X-OpenRouter-Title: $AICMD_TITLE"
    -d "$payload"
    -w $'\n%{http_code}'
  )

  if [[ -n "${AICMD_HTTP_REFERER:-}" ]]; then
    curl_args+=(-H "HTTP-Referer: $AICMD_HTTP_REFERER")
  fi

  response="$(command curl "${curl_args[@]}")"
  curl_status=$?
  if (( curl_status != 0 )); then
    __AICMD_ERROR="curl request failed"
    return 1
  fi

  __AICMD_HTTP_STATUS="${response##*$'\n'}"
  __AICMD_HTTP_BODY="${response%$'\n'*}"
  return 0
}

__aicmd_parse_model_text() {
  emulate -L zsh
  local text="$1"
  local line

  __AICMD_COMMAND=""
  __AICMD_EXPLANATION=""
  __AICMD_SAFETY=""
  __AICMD_CLARIFY=""

  while IFS= read -r line; do
    case "$line" in
      COMMAND:*)
        __AICMD_COMMAND="${line#COMMAND: }"
        [[ "$__AICMD_COMMAND" == "$line" ]] && __AICMD_COMMAND="${line#COMMAND:}"
        ;;
      EXPLANATION:*)
        __AICMD_EXPLANATION="${line#EXPLANATION: }"
        [[ "$__AICMD_EXPLANATION" == "$line" ]] && __AICMD_EXPLANATION="${line#EXPLANATION:}"
        ;;
      SAFETY:*)
        __AICMD_SAFETY="${${line#SAFETY: }:l}"
        [[ "$__AICMD_SAFETY" == "${line:l}" ]] && __AICMD_SAFETY="${${line#SAFETY:}:l}"
        ;;
      CLARIFY:*)
        __AICMD_CLARIFY="${line#CLARIFY: }"
        [[ "$__AICMD_CLARIFY" == "$line" ]] && __AICMD_CLARIFY="${line#CLARIFY:}"
        ;;
    esac
  done <<< "$text"

  [[ -n "$__AICMD_CLARIFY" ]] || __AICMD_CLARIFY="none"

  case "$__AICMD_SAFETY" in
    safe|caution|destructive|clarify) ;;
    *)
      __AICMD_ERROR="model response did not include a valid SAFETY field"
      return 1
      ;;
  esac

  if [[ "$__AICMD_SAFETY" == "clarify" && "$__AICMD_CLARIFY" == "none" ]]; then
    __AICMD_ERROR="model requested clarification without a question"
    return 1
  fi

  if [[ "$__AICMD_SAFETY" != "clarify" && -z "$__AICMD_COMMAND" ]]; then
    __AICMD_ERROR="model response did not include a command"
    return 1
  fi

  return 0
}

__aicmd_generate() {
  emulate -L zsh
  local prompt_text="$1"
  local target_shell="$2"
  local output_text error_code error_message

  __AICMD_COMMAND=""
  __AICMD_EXPLANATION=""
  __AICMD_SAFETY=""
  __AICMD_CLARIFY=""
  __AICMD_ERROR=""

  [[ -n "$prompt_text" ]] || {
    __AICMD_ERROR="prompt is required"
    return 1
  }

  __aicmd_call_openrouter "$prompt_text" "$target_shell" || return 1

  if [[ "$__AICMD_HTTP_STATUS" != 2* ]]; then
    error_code="$(__aicmd_extract_error_field "$__AICMD_HTTP_BODY" "code")"
    error_message="$(__aicmd_extract_error_field "$__AICMD_HTTP_BODY" "message")"
    if [[ -n "$error_code" || -n "$error_message" ]]; then
      __AICMD_ERROR="OpenRouter error ${error_code:-unknown}: ${error_message:-request failed}"
    else
      __AICMD_ERROR="OpenRouter request failed with HTTP $__AICMD_HTTP_STATUS"
    fi
    return 1
  fi

  output_text="$(__aicmd_extract_output_text "$__AICMD_HTTP_BODY")" || {
    __AICMD_ERROR="failed to parse model output from OpenRouter response"
    return 1
  }

  __aicmd_parse_model_text "$output_text"
}

__aicmd_generate_or_error() {
  emulate -L zsh
  local prompt_text="$1"
  local target_override="$2"
  local target_shell

  target_shell="$(__aicmd_effective_target_shell "$target_override")" || return 1
  __aicmd_generate "$prompt_text" "$target_shell" || return 1

  if [[ "$__AICMD_SAFETY" == "clarify" ]]; then
    __AICMD_ERROR="${__AICMD_CLARIFY:-more detail is required}"
    return 1
  fi

  if [[ "$__AICMD_SAFETY" == "destructive" ]] && ! __aicmd_confirm_destructive; then
    __AICMD_ERROR="command insertion cancelled"
    return 1
  fi

  return 0
}

__aicmd_confirm_destructive() {
  emulate -L zsh
  local reply

  if [[ ! -o interactive ]]; then
    __AICMD_ERROR="destructive command requires an interactive confirmation"
    return 1
  fi

  if [[ -n "$__AICMD_EXPLANATION" ]]; then
    __aicmd_err "$__AICMD_EXPLANATION"
  fi
  __aicmd_err "destructive command requires confirmation:"
  print -u2 -- "$__AICMD_COMMAND"
  printf 'Insert this command into the prompt? [y/N] ' >&2
  IFS= read -r reply </dev/tty
  case "${reply:l}" in
    y|yes) return 0 ;;
    *) return 1 ;;
  esac
}

__aicmd_insert_interactive_command() {
  emulate -L zsh
  local command_text="$1"

  if [[ -n "${WIDGET:-}" ]]; then
    BUFFER="$command_text"
    CURSOR=${#BUFFER}
    zle redisplay
    return 0
  fi

  if [[ -o interactive && -n "${ZSH_VERSION:-}" ]]; then
    print -z -- "$command_text"
    return 0
  fi

  print -r -- "$command_text"
}

__aicmd_usage() {
  cat <<'EOF'
Usage:
  aicmd [--zsh|--bash] "<natural language request>"
  aicmd-buffer [--zsh|--bash]
  aicmd-help

Behavior:
  - aicmd generates a shell command from a natural-language request.
  - In interactive zsh, aicmd pushes the command into the next prompt buffer.
  - In non-interactive shells, aicmd prints only the generated command.
  - aicmd-buffer replaces the current ZLE buffer and is meant for widget use.

Environment:
  OPENROUTER_API_KEY     Required API key for OpenRouter.
  AICMD_MODEL            Default: z-ai/glm-5-turbo
  AICMD_API_URL          Default: https://openrouter.ai/api/v1/responses
  AICMD_TARGET_SHELL     Default: auto (allowed: auto, zsh, bash)
  AICMD_TIMEOUT          Default: 30
  AICMD_HTTP_REFERER     Optional attribution header
  AICMD_TITLE            Optional title header (default: ai-cmd-oh-my-zsh)
  AICMD_INCLUDE_BUFFER   Default: 1
  AICMD_INCLUDE_ENV_CONTEXT Default: 1
  AICMD_ACCEPT_LINE_TRIGGER Default: 1
  AICMD_TRIGGER_PREFIX   Default: ##

Examples:
  aicmd "find the ten largest files here"
  aicmd --bash "list git branches merged into main"
  bindkey '^X^A' aicmd-widget
  export AICMD_ACCEPT_LINE_TRIGGER=1
  # Then type: ## find the ten largest files here
EOF
}

__aicmd_parse_cli() {
  emulate -L zsh
  local arg
  local -a prompt_parts

  __AICMD_ARG_TARGET_SHELL=""
  __AICMD_ARG_PROMPT=""

  for arg in "$@"; do
    case "$arg" in
      --zsh)
        __AICMD_ARG_TARGET_SHELL="zsh"
        ;;
      --bash)
        __AICMD_ARG_TARGET_SHELL="bash"
        ;;
      --help|-h)
        __aicmd_usage
        return 2
        ;;
      *)
        prompt_parts+=("$arg")
        ;;
    esac
  done

  __AICMD_ARG_PROMPT="${(j: :)prompt_parts}"
  return 0
}

aicmd() {
  emulate -L zsh
  local target_override prompt_text

  __aicmd_parse_cli "$@"
  case $? in
    0) ;;
    2) return 0 ;;
    *) return 1 ;;
  esac

  target_override="$__AICMD_ARG_TARGET_SHELL"
  prompt_text="$__AICMD_ARG_PROMPT"

  [[ -n "$prompt_text" ]] || {
    __aicmd_err "prompt is required"
    __aicmd_usage >&2
    return 1
  }

  __aicmd_generate_or_error "$prompt_text" "$target_override" || {
    __aicmd_err "$__AICMD_ERROR"
    return 1
  }

  __aicmd_insert_interactive_command "$__AICMD_COMMAND"
}

aicmd-buffer() {
  emulate -L zsh
  local target_override prompt_text original_buffer original_cursor

  if [[ -z "${WIDGET:-}" ]]; then
    __aicmd_err "aicmd-buffer must run inside a ZLE widget context"
    return 1
  fi

  __aicmd_parse_cli "$@"
  case $? in
    0) ;;
    2) return 0 ;;
    *) return 1 ;;
  esac

  target_override="$__AICMD_ARG_TARGET_SHELL"
  prompt_text="$__AICMD_ARG_PROMPT"

  original_buffer="$BUFFER"
  original_cursor="$CURSOR"
  prompt_text="${prompt_text:-$BUFFER}"

  [[ -n "$prompt_text" ]] || {
    __aicmd_err "BUFFER is empty"
    return 1
  }

  __aicmd_generate_or_error "$prompt_text" "$target_override" || {
    BUFFER="$original_buffer"
    CURSOR="$original_cursor"
    zle redisplay
    __aicmd_err "$__AICMD_ERROR"
    return 1
  }

  BUFFER="$__AICMD_COMMAND"
  CURSOR=${#BUFFER}
  zle redisplay
}

aicmd-help() {
  __aicmd_usage
}

aicmd-widget() {
  emulate -L zsh
  aicmd-buffer "$@"
}

aicmd-accept-line() {
  emulate -L zsh
  local original_buffer original_cursor trigger_prompt

  if __aicmd_is_truthy "${AICMD_ACCEPT_LINE_TRIGGER:-0}" && __aicmd_extract_trigger_prompt "$BUFFER"; then
    original_buffer="$BUFFER"
    original_cursor="$CURSOR"
    trigger_prompt="$REPLY"

    __aicmd_generate_or_error "$trigger_prompt" "" || {
      BUFFER="$original_buffer"
      CURSOR="$original_cursor"
      zle redisplay
      __aicmd_err "$__AICMD_ERROR"
      return 0
    }

    BUFFER="$__AICMD_COMMAND"
    CURSOR=${#BUFFER}
    zle redisplay
    return 0
  fi

  zle .accept-line
}

if [[ -n "${ZSH_VERSION:-}" && -o interactive ]]; then
  zle -N aicmd-widget
  zle -N aicmd-accept-line
  zle -N accept-line aicmd-accept-line
fi
