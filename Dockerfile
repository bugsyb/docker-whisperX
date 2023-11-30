# syntax=docker/dockerfile:1
ARG WHISPER_MODEL=base
ARG LANG=en

# When downloading diarization model with auth token, it seems that it is not respecting the TORCH_HOME env variable.
# So it is necessary to ensure that the CACHE_HOME is set to the exact same path as the default path.
# https://github.com/jim60105/docker-whisperX/issues/27
ARG CACHE_HOME=/.cache
ARG CONFIG_HOME=/.config
ARG TORCH_HOME=${CACHE_HOME}/torch
ARG HF_HOME=${CACHE_HOME}/huggingface

FROM python:3.10-slim as dependencies

# Setup venv
RUN python3 -m venv /venv
ARG PATH="/venv/bin:$PATH"
RUN --mount=type=cache,target=/root/.cache/pip pip install --upgrade pip setuptools

# Install requirements
RUN --mount=type=cache,target=/root/.cache/pip pip install torch torchaudio --extra-index-url https://download.pytorch.org/whl/cu118

# Add git
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends git

# Missing dependencies for arm64
# https://github.com/jim60105/docker-whisperX/issues/14
ARG TARGETPLATFORM
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
    apt-get install -y --no-install-recommends libgomp1 libsndfile1; \
    fi

# Install whisperX
COPY ./whisperX /code
RUN --mount=type=cache,target=/root/.cache/pip pip install /code


FROM dependencies as load_model

ARG TORCH_HOME
ARG HF_HOME
ARG PATH="/venv/bin:$PATH"

# Preload vad model
RUN python3 -c 'from whisperx.vad import load_vad_model; load_vad_model("cpu");'

# Preload fast-whisper
ARG WHISPER_MODEL
RUN python3 -c 'import faster_whisper; model = faster_whisper.WhisperModel("'${WHISPER_MODEL}'")'

# Preload align models
ARG LANG
COPY load_align_model.py .
RUN for i in ${LANG}; do echo "Aliging lang $i"; python3 load_align_model.py $i; done


FROM python:3.10-slim

# ffmpeg
COPY --link --from=mwader/static-ffmpeg:6.0 /ffmpeg /usr/local/bin/
COPY --link --from=mwader/static-ffmpeg:6.0 /ffprobe /usr/local/bin/

# Copy and use venv
COPY --link --from=dependencies /venv /venv
ARG PATH="/venv/bin:$PATH"
ENV PATH=${PATH}

# Missing dependencies for arm64
RUN if [ "$TARGETPLATFORM" = "linux/arm64" ]; then \
    apt-get install -y --no-install-recommends libgomp1 libsndfile1; \
    fi

ARG CACHE_HOME
ARG CONFIG_HOME
ARG TORCH_HOME
ARG HF_HOME
ENV XDG_CACHE_HOME=${CACHE_HOME}
ENV TORCH_HOME=${TORCH_HOME}
ENV HF_HOME=${HF_HOME}

COPY --link --chown=1001 --from=load_model ${CACHE_HOME} ${CACHE_HOME}
RUN mkdir -p ${CONFIG_HOME} && chown 1001:1001 ${CONFIG_HOME}

ARG WHISPER_MODEL
ENV WHISPER_MODEL=${WHISPER_MODEL}
ARG LANG
ENV LANG=${LANG}

USER 1001
WORKDIR /app

STOPSIGNAL SIGINT
# Take the first language from LANG env variable
ENTRYPOINT LANG=$(echo ${LANG} | cut -d ' ' -f1) && \
    whisperx --model "${WHISPER_MODEL}" --language "${LANG}" "$@" 
