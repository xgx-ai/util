{pkgs}: config: let
  inherit (pkgs) lib;

  cfg =
    {
      dataDir = ".data";
      env = {};
      extraPackages = _pkgs: [];
      install = "bun";
      portBlockSize = 20;
      portRangeSize = 30000;
      portRangeStart = 20000;
      secrets = null;
      services = {};
      shellHook = "";
      runtimeEnv = _ctx: {};
    }
    // config;

  shellPkgs = pkgs;

  services = cfg.services;
  serviceNames = builtins.attrNames services;
  commandServiceNames =
    builtins.filter (name: builtins.hasAttr "command" services.${name}) serviceNames;

  hasService = name: builtins.hasAttr name services;
  hasPostgres = hasService "postgres";
  hasRedis = hasService "redis";
  hasS3 = hasService "s3";

  serviceHasSubdomain = name: builtins.hasAttr "subdomain" services.${name};
  subdomainServiceNames = builtins.filter serviceHasSubdomain serviceNames;
  hasCaddy = subdomainServiceNames != [];

  portServiceNames =
    ["hivemind"]
    ++ commandServiceNames
    ++ lib.optional hasPostgres "postgres"
    ++ lib.optional hasRedis "redis"
    ++ lib.optional hasS3 "s3"
    ++ lib.optionals hasCaddy ["caddyHttp" "caddyHttps" "caddyAdmin"];

  upperServiceName = name:
    lib.toUpper (
      builtins.replaceStrings
      ["-" "."]
      ["_" "_"]
      name
    );

  portVarFor = name:
    {
      caddyHttp = "CADDY_HTTP_PORT";
      caddyHttps = "CADDY_HTTPS_PORT";
      caddyAdmin = "CADDY_ADMIN_PORT";
      postgres = "PGPORT";
    }
    .${name}
    or "${upperServiceName name}_PORT";

  urlVarFor = name: "${upperServiceName name}_URL";
  directUrlVarFor = name: "${upperServiceName name}_DIRECT_URL";

  shellArray = values:
    "(" + lib.concatMapStringsSep " " lib.escapeShellArg values + ")";

  shellAssoc = attrs:
    "("
    + lib.concatStringsSep " " (
      lib.mapAttrsToList (name: value: "[${lib.escapeShellArg name}]=${lib.escapeShellArg (toString value)}") attrs
    )
    + ")";

  portVarAssoc = lib.genAttrs portServiceNames portVarFor;

  commandAssoc = lib.genAttrs commandServiceNames (name: services.${name}.command);

  subdomainAssoc = lib.genAttrs subdomainServiceNames (name: services.${name}.subdomain);

  healthServiceNames =
    builtins.filter (
      name: builtins.hasAttr "health" services.${name}
    )
    commandServiceNames;
  healthAssoc = lib.genAttrs healthServiceNames (name: services.${name}.health);

  wildcardServiceNames =
    builtins.filter (
      name: services.${name}.wildcard or false
    )
    subdomainServiceNames;

  postgresCfg = services.postgres or {};
  postgresDatabase = postgresCfg.database or cfg.name;
  postgresExtensions = postgresCfg.extensions or [];
  postgresPackage =
    postgresCfg.package
    or (
      shellPkgs.postgresql.withPackages (
        ps:
          (postgresCfg.extensionPackages or (_ps: [])) ps
          ++ lib.optionals (builtins.elem "postgis" postgresExtensions) [ps.postgis]
      )
    );

  s3Cfg = services.s3 or {};
  s3Bucket = s3Cfg.bucket or "uploads";

  ctx = rec {
    literal = lib.escapeShellArg;
    domain = "\"$RUNTIME_DOMAIN\"";
    id = "\"$RUNTIME_ID\"";
    name = "\"$RUNTIME_NAME\"";
    dataRoot = "\"$DATA_ROOT\"";
    port = service: "\"$(runtime_port ${lib.escapeShellArg service})\"";
    url = service: "\"$(runtime_url ${lib.escapeShellArg service})\"";
    urlPath = service: path: "\"$(runtime_url ${lib.escapeShellArg service})${path}\"";
    directUrl = service: "\"$(runtime_direct_url ${lib.escapeShellArg service})\"";
    directUrlPath = service: path: "\"$(runtime_direct_url ${lib.escapeShellArg service})${path}\"";
  };

  runtimeEnvAttrs = cfg.runtimeEnv ctx;
  runtimeEnvLines = let
    lines =
      lib.mapAttrsToList (
        name: value: "  runtime_export ${name} ${value}"
      )
      runtimeEnvAttrs;
  in
    if lines == []
    then "  :"
    else lib.concatStringsSep "\n" lines;

  secretsFile =
    if cfg.secrets == null
    then null
    else cfg.secrets.file or "secrets.env";
  secretsLoadIntoEnv =
    if cfg.secrets == null
    then false
    else cfg.secrets.loadIntoEnv or false;

  usesBun =
    cfg.install == "bun"
    || builtins.any (
      name: lib.hasInfix "bun" services.${name}.command
    )
    commandServiceNames;

  standardPackages =
    [
      runtimeScripts
      shellPkgs.bash
      shellPkgs.coreutils
      shellPkgs.curl
      shellPkgs.gawk
      shellPkgs.git
      shellPkgs.lsof
      shellPkgs.perl
      shellPkgs.hivemind
      shellPkgs.figlet
    ]
    ++ lib.optional usesBun shellPkgs.bun
    ++ lib.optional hasCaddy shellPkgs.caddy
    ++ lib.optional hasPostgres postgresPackage
    ++ lib.optional hasRedis shellPkgs.valkey
    ++ lib.optional hasS3 shellPkgs.rclone
    ++ lib.optionals (cfg.secrets != null) [shellPkgs.sops shellPkgs.age];

  extraPackages =
    if builtins.isFunction cfg.extraPackages
    then cfg.extraPackages shellPkgs
    else cfg.extraPackages;

  configHash =
    builtins.hashString "sha256" (
      builtins.toJSON {
        inherit
          commandAssoc
          healthAssoc
          hasCaddy
          hasPostgres
          hasRedis
          hasS3
          portVarAssoc
          portServiceNames
          postgresDatabase
          postgresExtensions
          s3Bucket
          subdomainAssoc
          wildcardServiceNames
          ;
        name = cfg.name;
        runtimeEnvKeys = builtins.attrNames runtimeEnvAttrs;
      }
    );

  runtimeScripts = shellPkgs.runCommand "xgx-dev-runtime-${cfg.name}" {} ''
    mkdir -p "$out/bin"

    cat >"$out/bin/runtime" <<'RUNTIME'
    #!${shellPkgs.bash}/bin/bash
    set -euo pipefail

    RUNTIME_SCRIPT_VERSION=5
    RUNTIME_SCRIPT_CONFIG_HASH=${lib.escapeShellArg configHash}
    RUNTIME_PROJECT_NAME=${lib.escapeShellArg cfg.name}
    RUNTIME_DATA_DIR=${lib.escapeShellArg cfg.dataDir}
    PORT_BLOCK_SIZE=${toString cfg.portBlockSize}
    PORT_RANGE_START=${toString cfg.portRangeStart}
    PORT_RANGE_SIZE=${toString cfg.portRangeSize}

    runtime_port_names=${shellArray portServiceNames}
    runtime_health_names=${shellArray healthServiceNames}
    runtime_wildcard_names=${shellArray wildcardServiceNames}
    runtime_postgres_extensions=${shellArray postgresExtensions}

    declare -A runtime_port_vars=${shellAssoc portVarAssoc}
    declare -A runtime_commands=${shellAssoc commandAssoc}
    declare -A runtime_subdomains=${shellAssoc subdomainAssoc}
    declare -A runtime_health_paths=${shellAssoc healthAssoc}

    runtime_usage() {
      cat >&2 <<'USAGE'
    Usage:
      runtime load [--quiet]
      runtime print [--short]
      runtime run [--print] <command> [args...]
      runtime dev
      runtime withdev <command> [args...]
      runtime withpg <command> [args...]
      runtime check
      runtime repair
      runtime secrets path
    USAGE
    }

    runtime_project_dir() {
      if [ -n "''${XGX_RUNTIME_PROJECT_DIR:-}" ]; then
        printf '%s\n' "$XGX_RUNTIME_PROJECT_DIR"
        return 0
      fi

      git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || pwd
    }

    PROJECT_DIR="$(runtime_project_dir)"
    DATA_ROOT="$PROJECT_DIR/$RUNTIME_DATA_DIR"
    RUNTIME_FILE="$DATA_ROOT/runtime"
    RUNTIME_PROCFILE="$DATA_ROOT/Procfile"
    RUNTIME_CADDYFILE="$DATA_ROOT/Caddyfile"

    runtime_checksum() {
      shasum -a 256 <<<"$PROJECT_DIR" | awk '{print $1}'
    }

    runtime_slug() {
      local checksum
      checksum="$(runtime_checksum)"
      echo "''${checksum:0:6}"
    }

    runtime_realpath() {
      local path="$1"
      (cd "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
    }

    runtime_primary_worktree() {
      local worktree
      worktree="$(git -C "$PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk 'NR == 1 { sub(/^worktree /, ""); print; exit }' || true)"

      if [ -n "$worktree" ]; then
        runtime_realpath "$worktree"
      else
        runtime_realpath "$PROJECT_DIR"
      fi
    }

    runtime_is_primary_worktree() {
      [ "$(runtime_realpath "$PROJECT_DIR")" = "$(runtime_primary_worktree)" ]
    }

    runtime_default_branch() {
      local branch
      branch="$(git -C "$PROJECT_DIR" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)"
      branch="''${branch#origin/}"

      if [ -z "$branch" ]; then
        if git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/main; then
          branch="main"
        elif git -C "$PROJECT_DIR" show-ref --verify --quiet refs/heads/dev; then
          branch="dev"
        else
          branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)"
        fi
      fi

      echo "''${branch:-unknown}"
    }

    runtime_current_branch() {
      local branch
      branch="$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)"

      if [ -z "$branch" ]; then
        branch="$(git -C "$PROJECT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
      fi

      echo "''${branch:-unknown}"
    }

    runtime_kind() {
      if runtime_is_primary_worktree; then
        echo "canonical"
      else
        echo "worktree"
      fi
    }

    runtime_id() {
      if runtime_is_primary_worktree; then
        echo "$RUNTIME_PROJECT_NAME"
      else
        echo "$RUNTIME_PROJECT_NAME-$(runtime_slug)"
      fi
    }

    runtime_domain() {
      if runtime_is_primary_worktree; then
        echo "$RUNTIME_PROJECT_NAME.localhost"
      else
        echo "$RUNTIME_PROJECT_NAME-$(runtime_slug).localhost"
      fi
    }

    runtime_block_start() {
      local checksum seed block
      checksum="$(runtime_checksum)"
      seed=$((16#''${checksum:0:8}))
      block=$((PORT_RANGE_START + (seed % PORT_RANGE_SIZE)))
      block=$((block - (block % PORT_BLOCK_SIZE)))
      echo "$block"
    }

    runtime_port_has_listener() {
      local port="$1"
      lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    }

    runtime_port_block_is_free() {
      local block="$1"
      local offset

      for offset in $(seq 0 $((''${#runtime_port_names[@]} - 1))); do
        if runtime_port_has_listener "$((block + offset))"; then
          return 1
        fi
      done

      return 0
    }

    runtime_find_free_block() {
      local start="$1"
      local offset candidate

      for offset in $(seq 0 $((PORT_RANGE_SIZE / PORT_BLOCK_SIZE - 1))); do
        candidate=$((PORT_RANGE_START + ((start - PORT_RANGE_START + offset * PORT_BLOCK_SIZE) % PORT_RANGE_SIZE)))
        candidate=$((candidate - (candidate % PORT_BLOCK_SIZE)))

        if runtime_port_block_is_free "$candidate"; then
          echo "$candidate"
          return 0
        fi
      done

      echo "runtime: no free $PORT_BLOCK_SIZE-port block found" >&2
      return 1
    }

    runtime_write_export() {
      local name="$1"
      local value="$2"
      printf 'export %s=%q\n' "$name" "$value" >>"$RUNTIME_FILE"
    }

    runtime_export() {
      local name="$1"
      shift
      local value="$*"
      export "$name=$value"
      runtime_write_export "$name" "$value"
    }

    runtime_port_var() {
      local service="$1"
      echo "''${runtime_port_vars[$service]:-}"
    }

    runtime_port() {
      local service="$1"
      local var
      var="$(runtime_port_var "$service")"
      [ -n "$var" ] || return 1
      printf '%s\n' "''${!var}"
    }

    runtime_url_var() {
      local service="$1"
      echo "$(tr '[:lower:]-.' '[:upper:]__' <<<"$service")_URL"
    }

    runtime_direct_url_var() {
      local service="$1"
      echo "$(tr '[:lower:]-.' '[:upper:]__' <<<"$service")_DIRECT_URL"
    }

    runtime_url() {
      local service="$1"
      local var
      var="$(runtime_url_var "$service")"
      printf '%s\n' "''${!var:-}"
    }

    runtime_direct_url() {
      local service="$1"
      local var
      var="$(runtime_direct_url_var "$service")"
      printf '%s\n' "''${!var:-}"
    }

    runtime_write_project_env() {
    ${runtimeEnvLines}
    }

    runtime_write_caddyfile() {
      : >"$RUNTIME_CADDYFILE"

      if [ "''${#runtime_subdomains[@]}" -eq 0 ]; then
        return 0
      fi

      cat >>"$RUNTIME_CADDYFILE" <<EOF
    {
      admin localhost:$CADDY_ADMIN_PORT
      http_port $CADDY_HTTP_PORT
      https_port $CADDY_HTTPS_PORT
    }

    EOF

      local service subdomain port
      for service in "''${!runtime_subdomains[@]}"; do
        subdomain="''${runtime_subdomains[$service]}"
        port="$(runtime_port "$service")"

        if [ "$service" = "s3" ]; then
          cat >>"$RUNTIME_CADDYFILE" <<EOF
    $subdomain.$RUNTIME_DOMAIN {
      tls internal
      @cors_preflight method OPTIONS
      handle @cors_preflight {
        header Access-Control-Allow-Origin "{header.Origin}"
        header Access-Control-Allow-Methods "GET, PUT, POST, DELETE, HEAD, OPTIONS"
        header Access-Control-Allow-Headers "*"
        header Access-Control-Max-Age "3600"
        respond 204
      }
      reverse_proxy localhost:$port {
        header_down -Access-Control-Allow-Origin
        header_down -Access-Control-Allow-Methods
        header_down -Access-Control-Allow-Headers
      }
      header Access-Control-Allow-Origin "{header.Origin}"
      header Access-Control-Allow-Methods "GET, PUT, POST, DELETE, HEAD, OPTIONS"
      header Access-Control-Allow-Headers "*"
    }

    EOF
        else
          cat >>"$RUNTIME_CADDYFILE" <<EOF
    $subdomain.$RUNTIME_DOMAIN {
      tls internal
      reverse_proxy localhost:$port
    }

    EOF
        fi
      done

      for service in "''${runtime_wildcard_names[@]}"; do
        port="$(runtime_port "$service")"
        cat >>"$RUNTIME_CADDYFILE" <<EOF
    *.$RUNTIME_DOMAIN {
      tls internal
      reverse_proxy localhost:$port
    }

    EOF
      done

      if command -v caddy >/dev/null 2>&1; then
        caddy fmt --overwrite "$RUNTIME_CADDYFILE" >/dev/null 2>&1 || true
      fi
    }

    runtime_write_procfile() {
      : >"$RUNTIME_PROCFILE"

      local service
      for service in "''${!runtime_commands[@]}"; do
        printf '%-12s %s\n' "$service:" "cd \"\$RUNTIME_ROOT\" && ''${runtime_commands[$service]}" >>"$RUNTIME_PROCFILE"
      done

      if [ -n "''${PGPORT:-}" ]; then
        printf '%-12s %s\n' "postgres:" 'cd "$RUNTIME_ROOT" && runtime postgres-service' >>"$RUNTIME_PROCFILE"
      fi

      if [ -n "''${REDIS_PORT:-}" ]; then
        printf '%-12s %s\n' "redis:" 'cd "$RUNTIME_ROOT" && valkey-server --port $REDIS_PORT --dir "$REDIS_DATA" --daemonize no' >>"$RUNTIME_PROCFILE"
      fi

      if [ -n "''${S3_PORT:-}" ]; then
        printf '%-12s %s\n' "s3:" 'cd "$RUNTIME_ROOT" && rclone serve s3 "$DATA_ROOT/s3" --auth-key "$SERVER_R2_ACCESS_KEY,$SERVER_R2_SECRET_KEY" --addr ":$S3_PORT" --force-path-style' >>"$RUNTIME_PROCFILE"
      fi

      if [ -n "''${CADDY_HTTPS_PORT:-}" ]; then
        printf '%-12s %s\n' "caddy:" 'cd "$RUNTIME_ROOT" && caddy run --config "$RUNTIME_CADDYFILE"' >>"$RUNTIME_PROCFILE"
      fi
    }

    runtime_generate() {
      local start block offset service var port subdomain upper direct url
      start="$(runtime_block_start)"
      block="$(runtime_find_free_block "$start")"

      mkdir -p "$DATA_ROOT"
      : >"$RUNTIME_FILE"

      RUNTIME_ID="$(runtime_id)"
      RUNTIME_KIND="$(runtime_kind)"
      RUNTIME_DOMAIN="$(runtime_domain)"
      RUNTIME_BRANCH="$(runtime_current_branch)"
      RUNTIME_DEFAULT_BRANCH="$(runtime_default_branch)"
      RUNTIME_PRIMARY_WORKTREE="$(runtime_primary_worktree)"

      runtime_export RUNTIME_VERSION "$RUNTIME_SCRIPT_VERSION"
      runtime_export RUNTIME_CONFIG_HASH "$RUNTIME_SCRIPT_CONFIG_HASH"
      runtime_export RUNTIME_NAME "$RUNTIME_PROJECT_NAME"
      runtime_export RUNTIME_ROOT "$PROJECT_DIR"
      runtime_export RUNTIME_ID "$RUNTIME_ID"
      runtime_export RUNTIME_KIND "$RUNTIME_KIND"
      runtime_export RUNTIME_SLUG "$(runtime_slug)"
      runtime_export RUNTIME_DOMAIN "$RUNTIME_DOMAIN"
      runtime_export RUNTIME_PORT_BLOCK "$block"
      runtime_export RUNTIME_PRIMARY_WORKTREE "$RUNTIME_PRIMARY_WORKTREE"
      runtime_export RUNTIME_DEFAULT_BRANCH "$RUNTIME_DEFAULT_BRANCH"
      runtime_export RUNTIME_BRANCH "$RUNTIME_BRANCH"
      runtime_export DATA_ROOT "$DATA_ROOT"
      runtime_export RUNTIME_PROCFILE "$RUNTIME_PROCFILE"
      runtime_export RUNTIME_CADDYFILE "$RUNTIME_CADDYFILE"

      offset=0
      for service in "''${runtime_port_names[@]}"; do
        var="''${runtime_port_vars[$service]}"
        port="$((block + offset))"
        runtime_export "$var" "$port"
        offset="$((offset + 1))"
      done

      if [ -n "''${PGPORT:-}" ]; then
        runtime_export PGDATA "$DATA_ROOT/postgres"
        runtime_export PGHOST "$DATA_ROOT/postgres"
        runtime_export POSTGRES_PORT "$PGPORT"
        runtime_export PGDATABASE ${lib.escapeShellArg postgresDatabase}
        runtime_export DATABASE_URL "postgres://127.0.0.1:$PGPORT/$PGDATABASE"
        mkdir -p "$PGDATA"
      fi

      if [ -n "''${REDIS_PORT:-}" ]; then
        runtime_export REDIS_DATA "$DATA_ROOT/redis"
        runtime_export REDIS_URL "redis://127.0.0.1:$REDIS_PORT"
        mkdir -p "$REDIS_DATA"
      fi

      if [ -n "''${S3_PORT:-}" ]; then
        runtime_export S3_BUCKET ${lib.escapeShellArg s3Bucket}
        mkdir -p "$DATA_ROOT/s3/$S3_BUCKET"
      fi

      for service in "''${runtime_port_names[@]}"; do
        upper="$(tr '[:lower:]-.' '[:upper:]__' <<<"$service")"
        port="$(runtime_port "$service")"
        direct="http://localhost:$port"
        runtime_export "''${upper}_DIRECT_URL" "$direct"

        if [ "$service" = "redis" ] || [ "$service" = "postgres" ]; then
          continue
        fi

        if [ -n "''${runtime_subdomains[$service]:-}" ] && [ -n "''${CADDY_HTTPS_PORT:-}" ]; then
          subdomain="''${runtime_subdomains[$service]}"
          url="https://$subdomain.$RUNTIME_DOMAIN:$CADDY_HTTPS_PORT"
          runtime_export "''${upper}_URL" "$url"
        else
          runtime_export "''${upper}_URL" "$direct"
        fi
      done

      runtime_write_project_env
      runtime_write_caddyfile
      runtime_write_procfile
    }

    runtime_file_is_valid() {
      if [ ! -f "$RUNTIME_FILE" ]; then
        return 1
      fi

      # shellcheck disable=SC1090
      . "$RUNTIME_FILE"

      [ "''${RUNTIME_VERSION:-}" = "$RUNTIME_SCRIPT_VERSION" ] &&
        [ "''${RUNTIME_CONFIG_HASH:-}" = "$RUNTIME_SCRIPT_CONFIG_HASH" ] &&
        [ "''${RUNTIME_ROOT:-}" = "$PROJECT_DIR" ] &&
        [ "''${RUNTIME_ID:-}" = "$(runtime_id)" ] &&
        [ "''${RUNTIME_DOMAIN:-}" = "$(runtime_domain)" ]
    }

    runtime_load() {
      local quiet=false

      if [ "''${1:-}" = "--quiet" ]; then
        quiet=true
      fi

      if ! runtime_file_is_valid; then
        runtime_generate
      fi

      # shellcheck disable=SC1090
      . "$RUNTIME_FILE"

      if ! $quiet; then
        runtime_print
      fi
    }

    runtime_print() {
      local short=false

      if [ "''${1:-}" = "--short" ]; then
        short=true
      fi

      runtime_load --quiet

      if $short; then
        cat <<EOF
    runtime: $RUNTIME_ID ($RUNTIME_KIND)
    domain:  $RUNTIME_DOMAIN
    ports:   block $RUNTIME_PORT_BLOCK
    EOF
        for service in "''${!runtime_subdomains[@]}"; do
          printf '%-8s %s\n' "$service:" "$(runtime_url "$service")"
        done
        return 0
      fi

      cat <<EOF
    $RUNTIME_NAME runtime
      id:       $RUNTIME_ID
      kind:     $RUNTIME_KIND
      branch:   $RUNTIME_BRANCH (default: $RUNTIME_DEFAULT_BRANCH)
      domain:   $RUNTIME_DOMAIN
      data:     $DATA_ROOT

    Services
    EOF

      for service in "''${runtime_port_names[@]}"; do
        printf '  %-12s port %-6s url %s\n' "$service" "$(runtime_port "$service")" "$(runtime_url "$service")"
      done
    }

    runtime_check_port() {
      local name="$1"
      local port="$2"
      local listener

      listener="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1 " pid=" $2}' || true)"

      if [ -n "$listener" ]; then
        printf '%-12s %-6s %s\n' "$name" "$port" "$listener"
      else
        printf '%-12s %-6s free\n' "$name" "$port"
      fi
    }

    runtime_check() {
      runtime_load --quiet

      printf '%-12s %-6s %s\n' "service" "port" "status"
      local service
      for service in "''${runtime_port_names[@]}"; do
        runtime_check_port "$service" "$(runtime_port "$service")"
      done
    }

    runtime_run() {
      local print=false

      if [ "''${1:-}" = "--print" ]; then
        print=true
        shift
      fi

      if [ $# -eq 0 ]; then
        echo "runtime: missing command for run" >&2
        runtime_usage
        return 1
      fi

      runtime_load --quiet

      if $print; then
        runtime_print --short
      fi

      exec "$@"
    }

    runtime_repair() {
      rm -f "$RUNTIME_FILE"
      runtime_generate
      runtime_print --short
    }

    runtime_dev() {
      runtime_load --quiet
      exec hivemind "$RUNTIME_PROCFILE"
    }

    runtime_stack_healthy() {
      runtime_load --quiet

      local service path url
      for service in "''${runtime_health_names[@]}"; do
        path="''${runtime_health_paths[$service]}"
        url="$(runtime_direct_url "$service")$path"
        curl -sf --max-time 0.5 "$url" >/dev/null 2>&1 || return 1
      done

      if [ -n "''${PGPORT:-}" ]; then
        runtime_postgres_healthy || return 1
      fi

      return 0
    }

    runtime_postgres_healthy() {
      [ -n "''${PGHOST:-}" ] || return 1
      [ -n "''${PGPORT:-}" ] || return 1
      pg_isready -q -h "$PGHOST" -p "$PGPORT"
    }

    runtime_with_lock() {
      local lock_file="''${1:-}"
      shift || true

      if [ -z "$lock_file" ] || [ $# -eq 0 ]; then
        echo "Usage: runtime_with_lock <lock-file> <command> [args...]" >&2
        return 1
      fi

      mkdir -p "$(dirname "$lock_file")"
      ${shellPkgs.perl}/bin/perl -MFcntl=:flock -e '
        my ($lock_file, @command) = @ARGV;
        open(my $lock, ">", $lock_file) or die "lock: cannot open $lock_file: $!\n";
        flock($lock, LOCK_EX) or die "lock: cannot lock $lock_file: $!\n";
        system @command;
        my $status = $?;
        if ($status == -1) {
          die "lock: failed to run $command[0]: $!\n";
        }
        if ($status & 127) {
          exit(128 + ($status & 127));
        }
        exit($status >> 8);
      ' "$lock_file" "$@"
    }

    runtime_postgres_lock_file() {
      printf '%s\n' "''${DATA_ROOT:-$PGDATA/..}/postgres.lifecycle.lock"
    }

    runtime_bootstrap_postgres() {
      runtime_load --quiet

      if [ -z "''${PGDATA:-}" ] || [ -z "''${PGHOST:-}" ] || [ -z "''${PGPORT:-}" ]; then
        echo "PGDATA, PGHOST, and PGPORT are not configured" >&2
        return 1
      fi

      if [ ! -f "$PGDATA/PG_VERSION" ]; then
        mkdir -p "$PGDATA"
        initdb --no-locale --encoding=UTF8 --auth=trust
      fi

      if ! runtime_postgres_healthy; then
        echo "postgres: starting..."
        pg_ctl start -s -D "$PGDATA" -l "$PGDATA/../postgres.log" -o "-k $PGHOST -p $PGPORT"
      fi

      if ! runtime_postgres_healthy; then
        echo "postgres: failed to start" >&2
        return 1
      fi

      psql -h "$PGHOST" -p "$PGPORT" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$PGDATABASE'" | grep -q 1 ||
        createdb -h "$PGHOST" -p "$PGPORT" "$PGDATABASE"

      local extension
      for extension in "''${runtime_postgres_extensions[@]}"; do
        psql -h "$PGHOST" -p "$PGPORT" -d "$PGDATABASE" -c "create extension if not exists $extension" >/dev/null
      done
    }

    runtime_hold_postgres() {
      while runtime_postgres_healthy; do
        sleep 2
      done

      echo "postgres: stopped or became unavailable" >&2
      return 1
    }

    runtime_postgres_service() {
      runtime_load --quiet

      if runtime_postgres_healthy; then
        was_running=true
      else
        was_running=false
      fi

      cleanup() {
        if [ "''${was_running:-true}" != "true" ]; then
          echo "postgres: stopping..."
          pg_ctl stop -s -D "$PGDATA" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT

      if ! $was_running; then
        runtime_with_lock "$(runtime_postgres_lock_file)" "$(command -v runtime)" bootstrap-postgres || return 1
      fi

      runtime_hold_postgres
    }

    runtime_ports_have_listeners() {
      runtime_load --quiet

      local service
      for service in "''${runtime_port_names[@]}"; do
        if runtime_port_has_listener "$(runtime_port "$service")"; then
          return 0
        fi
      done

      return 1
    }

    runtime_wait_for_stack() {
      local pid="''${1:-}"

      echo -n "dev: waiting for stack"
      for _ in $(seq 1 300); do
        if runtime_stack_healthy; then
          echo " ready"
          return 0
        fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
          echo " failed (hivemind exited)"
          echo "Check $DATA_ROOT/hivemind.log for details" >&2
          return 1
        fi
        echo -n "."
        sleep 0.2
      done

      echo " timed out"
      return 1
    }

    runtime_withdev() {
      if [ $# -eq 0 ]; then
        echo "Usage: runtime withdev <command> [args...]" >&2
        return 1
      fi

      runtime_load --quiet

      if runtime_stack_healthy; then
        was_running=true
      elif runtime_ports_have_listeners; then
        was_running=true
        runtime_wait_for_stack
      else
        was_running=false
      fi

      if ! $was_running; then
        mkdir -p "$DATA_ROOT"
        echo "dev: starting..."
        (runtime_dev) &>"$DATA_ROOT/hivemind.log" &
        HIVEMIND_PID=$!

        if ! runtime_wait_for_stack "$HIVEMIND_PID"; then
          kill "$HIVEMIND_PID" 2>/dev/null
          return 1
        fi
      fi

      cleanup() {
        if ! $was_running; then
          echo "dev: stopping..."
          kill "$HIVEMIND_PID" 2>/dev/null
          wait "$HIVEMIND_PID" 2>/dev/null || true
        fi
      }
      trap cleanup EXIT

      "$@"
    }

    runtime_withpg() {
      if [ $# -eq 0 ]; then
        echo "Usage: runtime withpg <command> [args...]" >&2
        return 1
      fi

      runtime_load --quiet

      if [ -z "''${PGDATA:-}" ] || [ -z "''${PGHOST:-}" ] || [ -z "''${PGPORT:-}" ]; then
        echo "PGDATA, PGHOST, and PGPORT are not configured" >&2
        return 1
      fi

      if ! runtime_postgres_healthy; then
        runtime_with_lock "$(runtime_postgres_lock_file)" "$(command -v runtime)" bootstrap-postgres || return 1
      fi

      "$@"
    }

    runtime_secrets() {
      case "''${1:-}" in
        path)
          printf '%s\n' "''${XGX_SECRETS_FILE:-}"
          ;;
        *)
          echo "Usage: runtime secrets path" >&2
          return 1
          ;;
      esac
    }

    runtime_main() {
      local command="''${1:-}"
      shift || true

      case "$command" in
        load)
          runtime_load "$@"
          ;;
        print)
          runtime_print "$@"
          ;;
        run)
          runtime_run "$@"
          ;;
        dev)
          runtime_dev "$@"
          ;;
        withdev)
          runtime_withdev "$@"
          ;;
        withpg)
          runtime_withpg "$@"
          ;;
        bootstrap-postgres)
          runtime_bootstrap_postgres
          ;;
        postgres-service)
          runtime_postgres_service
          ;;
        hold-postgres)
          runtime_hold_postgres
          ;;
        check)
          runtime_check
          ;;
        repair)
          runtime_repair
          ;;
        secrets)
          runtime_secrets "$@"
          ;;
        *)
          runtime_usage
          return 1
          ;;
      esac
    }

    runtime_main "$@"
    RUNTIME

    sed -i 's/^    //' "$out/bin/runtime"
    chmod +x "$out/bin/runtime"

    cat >"$out/bin/withdev" <<EOF
    #!${shellPkgs.bash}/bin/bash
    exec "$out/bin/runtime" withdev "\$@"
    EOF
    sed -i 's/^    //' "$out/bin/withdev"
    chmod +x "$out/bin/withdev"

    cat >"$out/bin/withpg" <<EOF
    #!${shellPkgs.bash}/bin/bash
    exec "$out/bin/runtime" withpg "\$@"
    EOF
    sed -i 's/^    //' "$out/bin/withpg"
    chmod +x "$out/bin/withpg"
  '';

  secretsHook =
    if cfg.secrets == null
    then ''
      unset XGX_SECRETS_FILE
      export XGX_SECRETS_LOAD_INTO_ENV=0
    ''
    else ''
      export XGX_SECRETS_FILE="$PWD/${secretsFile}"
      export XGX_SECRETS_LOAD_INTO_ENV=${if secretsLoadIntoEnv then "1" else "0"}

      if [ "$XGX_SECRETS_LOAD_INTO_ENV" = "1" ]; then
        if [ ! -f "$XGX_SECRETS_FILE" ]; then
          echo "sops: warning: $XGX_SECRETS_FILE not found; continuing without secrets" >&2
        elif ! command -v sops >/dev/null 2>&1; then
          echo "sops: warning: sops is not available; continuing without secrets" >&2
        else
          secrets_env_tmp="$(mktemp)"
          if sops -d "$XGX_SECRETS_FILE" >"$secrets_env_tmp" 2>/dev/null; then
            echo sops: loading "$XGX_SECRETS_FILE"
            set -a
            if ! source "$secrets_env_tmp"; then
              echo "sops: warning: could not source $XGX_SECRETS_FILE; continuing with partial secrets" >&2
            fi
            set +a
          else
            echo "sops: warning: could not decrypt $XGX_SECRETS_FILE; continuing without secrets" >&2
          fi
          rm -f "$secrets_env_tmp"
        fi
      fi
    '';

  installHook =
    if cfg.install == "bun"
    then ''
      echo bun: installing deps
      bun install --silent
    ''
    else if cfg.install == null
    then ""
    else cfg.install;

  caddyTrustHook =
    if hasCaddy
    then ''
      export NODE_EXTRA_CA_CERTS="$HOME/.local/share/caddy/pki/authorities/local/root.crt"
    ''
    else "";
in
  shellPkgs.mkShell {
    packages = standardPackages ++ extraPackages;
    env = cfg.env;

    shellHook = ''
      export XDG_CONFIG_HOME="''${XDG_CONFIG_HOME:-$HOME/.config}"

      ${secretsHook}

      source "$(command -v runtime)" load --quiet

      ${caddyTrustHook}

      ${installHook}

      if command -v figlet >/dev/null 2>&1; then
        figlet "$RUNTIME_NAME"
      else
        printf '%s\n' "$RUNTIME_NAME"
      fi
      runtime print --short

      ${cfg.shellHook}
    '';
  }
