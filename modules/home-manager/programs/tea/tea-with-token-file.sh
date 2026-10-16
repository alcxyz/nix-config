# Body of the tea wrapper (default.nix), which binds tea_bin, tea_url and
# tea_login before it.
token_file=${FORGEJO_API_TOKEN_FILE:-}
token=
if [ -n "$token_file" ] && [ -f "$token_file" ] && [ -r "$token_file" ]; then
  token=$(<"$token_file")
fi
args=("$@")
if [ -n "${token//[[:space:]]/}" ]; then
  GITEA_TOKEN=$token
  GITEA_INSTANCE_URL=$tea_url
  export GITEA_TOKEN GITEA_INSTANCE_URL
  # T3 Code finds the managed login in `tea login list` and names it with
  # --login, which would select that token-less login over the environment
  # login (#704). Drop it; another login named explicitly is kept.
  args=()
  while (($#)); do
    case $1 in
      --)
        args+=("$@")
        break
        ;;
      --login | -l)
        if (($# > 1)) && [[ $2 == "$tea_login" ]]; then
          shift 2
          continue
        fi
        ;;
      --login=* | -l=*)
        if [[ ${1#*=} == "$tea_login" ]]; then
          shift
          continue
        fi
        ;;
    esac
    args+=("$1")
    shift
  done
elif [ -n "$token_file" ]; then
  echo "tea: no token in $token_file; using stored logins" >&2
fi
unset token
exec "$tea_bin" "${args[@]}"
