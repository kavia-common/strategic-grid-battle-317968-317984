#!/bin/bash
set -euo pipefail

# Schema initializer for the strategy game database.
# This script is intended to be called from startup.sh after PostgreSQL is ready.
#
# It is designed to be idempotent:
# - Uses CREATE TABLE IF NOT EXISTS / CREATE INDEX IF NOT EXISTS
# - Uses DO blocks to create enums only if missing
# - Uses CREATE OR REPLACE for functions

DB_NAME="${DB_NAME:-myapp}"
DB_USER="${DB_USER:-appuser}"
DB_PORT="${DB_PORT:-5000}"

PG_VERSION="$(ls /usr/lib/postgresql/ | head -1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Running schema initialization for ${DB_NAME} as ${DB_USER} on port ${DB_PORT}..."

PSQL_BASE=(sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1)

# Helper to run a single SQL statement (per platform guidance: execute statements one-at-a-time).
run_sql () {
  local stmt="$1"
  "${PSQL_BASE[@]}" -c "${stmt}"
}

# Keep all objects in public schema
run_sql "SET search_path TO public;"

# ---- Extensions ----
run_sql "CREATE EXTENSION IF NOT EXISTS pgcrypto;"

# ---- Enums (created conditionally) ----
run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lobby_status') THEN
    CREATE TYPE lobby_status AS ENUM ('open','in_game','closed');
  END IF;
END \$\$;"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'game_status') THEN
    CREATE TYPE game_status AS ENUM ('waiting','active','finished','abandoned');
  END IF;
END \$\$;"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'player_status') THEN
    CREATE TYPE player_status AS ENUM ('joined','ready','left','disconnected');
  END IF;
END \$\$;"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'action_type') THEN
    CREATE TYPE action_type AS ENUM ('move','attack','ability','end_turn','surrender');
  END IF;
END \$\$;"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'match_result') THEN
    CREATE TYPE match_result AS ENUM ('win','loss','draw','abandoned');
  END IF;
END \$\$;"

# ---- Utility trigger to keep updated_at in sync ----
run_sql "CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS \$\$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
\$\$;"

# ---- Users ----
run_sql "CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE,
  username text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  display_name text,
  avatar_url text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  last_login_at timestamptz
);"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_users_updated_at') THEN
    CREATE TRIGGER trg_users_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END \$\$;"

# ---- Lobbies ----
run_sql "CREATE TABLE IF NOT EXISTS lobbies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  name text NOT NULL,
  host_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  status lobby_status NOT NULL DEFAULT 'open',
  max_players int NOT NULL DEFAULT 2,
  is_private boolean NOT NULL DEFAULT false,
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_lobbies_updated_at') THEN
    CREATE TRIGGER trg_lobbies_updated_at
    BEFORE UPDATE ON lobbies
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END \$\$;"

run_sql "CREATE TABLE IF NOT EXISTS lobby_players (
  lobby_id uuid NOT NULL REFERENCES lobbies(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slot int NOT NULL,
  status player_status NOT NULL DEFAULT 'joined',
  joined_at timestamptz NOT NULL DEFAULT NOW(),
  ready_at timestamptz,
  left_at timestamptz,
  PRIMARY KEY (lobby_id, user_id),
  UNIQUE (lobby_id, slot)
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_lobby_players_lobby ON lobby_players(lobby_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_lobby_players_user ON lobby_players(user_id);"

# ---- Games ----
run_sql "CREATE TABLE IF NOT EXISTS games (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  lobby_id uuid REFERENCES lobbies(id) ON DELETE SET NULL,
  status game_status NOT NULL DEFAULT 'waiting',
  map_width int NOT NULL,
  map_height int NOT NULL,
  map_seed text,
  map_state jsonb NOT NULL DEFAULT '{}'::jsonb,
  started_at timestamptz,
  finished_at timestamptz,
  current_turn int NOT NULL DEFAULT 1,
  current_player_index int NOT NULL DEFAULT 0,
  turn_expires_at timestamptz,
  winning_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  result_reason text,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_games_updated_at') THEN
    CREATE TRIGGER trg_games_updated_at
    BEFORE UPDATE ON games
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END \$\$;"

run_sql "CREATE INDEX IF NOT EXISTS idx_games_lobby ON games(lobby_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_games_status ON games(status);"
run_sql "CREATE INDEX IF NOT EXISTS idx_games_turn_expires ON games(turn_expires_at);"

run_sql "CREATE TABLE IF NOT EXISTS game_players (
  game_id uuid NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  player_index int NOT NULL,
  team int NOT NULL DEFAULT 0,
  is_ai boolean NOT NULL DEFAULT false,
  joined_at timestamptz NOT NULL DEFAULT NOW(),
  eliminated_at timestamptz,
  PRIMARY KEY (game_id, user_id),
  UNIQUE (game_id, player_index)
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_game_players_game ON game_players(game_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_game_players_user ON game_players(user_id);"

# ---- Units ----
run_sql "CREATE TABLE IF NOT EXISTS units (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  owner_user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  unit_type text NOT NULL,
  name text,
  x int NOT NULL,
  y int NOT NULL,
  hp int NOT NULL,
  max_hp int NOT NULL,
  attack int NOT NULL DEFAULT 0,
  defense int NOT NULL DEFAULT 0,
  movement int NOT NULL DEFAULT 0,
  range int NOT NULL DEFAULT 1,
  status_effects jsonb NOT NULL DEFAULT '[]'::jsonb,
  cooldowns jsonb NOT NULL DEFAULT '{}'::jsonb,
  is_alive boolean NOT NULL DEFAULT true,
  spawned_turn int NOT NULL DEFAULT 1,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW()
);"

run_sql "DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_units_updated_at') THEN
    CREATE TRIGGER trg_units_updated_at
    BEFORE UPDATE ON units
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END \$\$;"

run_sql "CREATE INDEX IF NOT EXISTS idx_units_game ON units(game_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_units_owner ON units(owner_user_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_units_game_pos ON units(game_id, x, y);"

# Ensure there can't be two alive units on the same tile (dead units can remain for history if desired).
run_sql "CREATE UNIQUE INDEX IF NOT EXISTS ux_units_alive_tile
ON units(game_id, x, y)
WHERE is_alive = true;"

# ---- Turns / Actions ----
run_sql "CREATE TABLE IF NOT EXISTS turns (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  turn_number int NOT NULL,
  player_index int NOT NULL,
  started_at timestamptz NOT NULL DEFAULT NOW(),
  ended_at timestamptz,
  time_limit_seconds int,
  ended_reason text,
  UNIQUE (game_id, turn_number, player_index)
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_turns_game_turn ON turns(game_id, turn_number);"

run_sql "CREATE TABLE IF NOT EXISTS actions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid NOT NULL REFERENCES games(id) ON DELETE CASCADE,
  turn_id uuid REFERENCES turns(id) ON DELETE SET NULL,
  actor_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  actor_unit_id uuid REFERENCES units(id) ON DELETE SET NULL,
  action_type action_type NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW()
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_actions_game_created ON actions(game_id, created_at);"
run_sql "CREATE INDEX IF NOT EXISTS idx_actions_turn ON actions(turn_id);"
run_sql "CREATE INDEX IF NOT EXISTS idx_actions_actor_user ON actions(actor_user_id);"

# ---- Match history ----
run_sql "CREATE TABLE IF NOT EXISTS matches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  game_id uuid UNIQUE REFERENCES games(id) ON DELETE SET NULL,
  started_at timestamptz,
  finished_at timestamptz,
  result match_result NOT NULL DEFAULT 'abandoned',
  winning_user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  summary jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT NOW()
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_matches_finished_at ON matches(finished_at);"
run_sql "CREATE INDEX IF NOT EXISTS idx_matches_winner ON matches(winning_user_id);"

run_sql "CREATE TABLE IF NOT EXISTS match_players (
  match_id uuid NOT NULL REFERENCES matches(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE RESTRICT,
  result match_result NOT NULL,
  stats jsonb NOT NULL DEFAULT '{}'::jsonb,
  player_index int,
  team int,
  PRIMARY KEY (match_id, user_id)
);"

run_sql "CREATE INDEX IF NOT EXISTS idx_match_players_user ON match_players(user_id);"

# ---- Simple schema versioning ----
run_sql "CREATE TABLE IF NOT EXISTS schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT NOW()
);"

# Mark this baseline as applied (idempotent)
run_sql "INSERT INTO schema_migrations(version) VALUES ('0001_baseline_strategy_game') ON CONFLICT (version) DO NOTHING;"

echo "Schema initialization complete."
