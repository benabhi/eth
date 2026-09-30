# Imagen de producción de EVE Trade Hunter (RNF-10.5): release de Elixir en dos etapas.
# La usa docker-compose.release.yml; el desarrollo sigue con Dockerfile.dev.
#
# Imágenes base: hexpm/elixir (compilación) y debian (ejecución), misma versión de Debian.
# Tags disponibles: https://bob.hex.pm/docker?repo=hexpm/elixir&os=debian

ARG ELIXIR_VERSION=1.20.4
ARG OTP_VERSION=29.1.1
ARG DEBIAN_VERSION=trixie-20260918-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# ─── Compilación ────────────────────────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencias primero: se recompilan solo si cambia mix.lock o la configuración.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

# runtime.exs se lee al arrancar: cambiarlo no recompila.
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ─── Ejecución ──────────────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS final

# libsctp1: evita el aviso "Failed open sctp dynamic library" de la VM en cada comando.
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 libsctp1 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR "/app"
RUN chown nobody /app

# Datos persistentes (SDE procesado, matrices, snapshots y la clave de cookies) fuera de
# la release: sobreviven a las actualizaciones (RNF-10.7). El volumen hereda el dueño.
RUN mkdir -p /data && chown nobody:root /data
ENV ETH_DATA_DIR=/data

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/eth ./

USER nobody

# Las migraciones corren solas en cada arranque (RNF-10.3) y después arranca el servidor.
CMD ["/bin/sh", "-c", "/app/bin/migrate && exec /app/bin/server"]
