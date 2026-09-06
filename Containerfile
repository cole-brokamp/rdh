ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG R_VERSION
ARG MS_REPO_DEB_SHA256=c13f01ac7c3001b51a9281d40dde666db5e037e05512840c319832f7852bfec4
ARG MSODBCSQL_VERSION=18.6.2.1-1
ARG PPM_REPO

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    R_VERSION=${R_VERSION} \
    R_LIBS_SITE=/opt/datahub-r/site-library \
    DATAHUB_R_PPM_REPO=${PPM_REPO}

# The fully specified Posit tag fixes the R patch version while allowing the
# image publisher to rebuild that tag with OS and security updates.
RUN case "$(dpkg --print-architecture)" in \
        amd64|arm64) ;; \
        *) echo "unsupported image architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && test "$(Rscript -e 'cat(as.character(getRversion()))')" = "${R_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        gfortran \
        git \
        gnupg \
        libcurl4-openssl-dev \
        libicu-dev \
        libssl-dev \
        libxml2-dev \
        locales \
        make \
        pkg-config \
        unixodbc \
        unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --silent --show-error \
        "https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb" \
        --output /tmp/packages-microsoft-prod.deb \
    && echo "${MS_REPO_DEB_SHA256}  /tmp/packages-microsoft-prod.deb" | sha256sum --check --strict \
    && dpkg -i /tmp/packages-microsoft-prod.deb \
    && rm -f /tmp/packages-microsoft-prod.deb \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends \
        "msodbcsql18=${MSODBCSQL_VERSION}" \
    && rm -rf /var/lib/apt/lists/* \
    && odbcinst -q -d | grep -Fx '[ODBC Driver 18 for SQL Server]'

RUN install -d -o root -g root -m 0755 \
        /opt/datahub-r \
        /opt/datahub-r/site-library

COPY pkg.lock /opt/datahub-r/pkg.lock
COPY container/install-locked.R /opt/datahub-r/install-locked.R

# Bootstrap pak through PPM, then install every direct and transitive package at
# the exact version in the committed lock. The installer also writes a manifest
# and fails if the installed library and lock disagree.
RUN Rscript -e 'options(repos = c(CRAN = Sys.getenv("DATAHUB_R_PPM_REPO"))); install.packages("pak", lib = Sys.getenv("R_LIBS_SITE"), dependencies = NA)' \
    && Rscript /opt/datahub-r/install-locked.R

COPY VERSION /opt/datahub-r/VERSION
COPY container/Rprofile.site "/opt/R/${R_VERSION}/lib/R/etc/Rprofile.site"
COPY container/database.R /opt/datahub-r/database.R
COPY container/check.R /opt/datahub-r/check.R
COPY container/smoke.R /opt/datahub-r/smoke.R

ARG DATAHUB_R_VERSION

# VERSION is the release-version authority. The build caller supplies the same
# value as an argument so OCI metadata cannot silently drift from the checkout.
RUN test -n "${DATAHUB_R_VERSION}" \
    && test "$(tr -d '\r\n' < /opt/datahub-r/VERSION)" = "${DATAHUB_R_VERSION}"

RUN chmod -R a=rX /opt/datahub-r \
    && Rscript /opt/datahub-r/smoke.R

# Build metadata belongs to the OCI labels and does not invalidate dependency layers.
ARG BUILD_DATE=unknown
ARG VCS_REF=uncommitted
ARG PACKAGE_LOCK_SHA256=unknown

LABEL org.opencontainers.image.title="datahub-r" \
      org.opencontainers.image.description="R environment for CCHMC DataHub SQL Server work" \
      org.opencontainers.image.version="${DATAHUB_R_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      io.datahub-r.r.version="${R_VERSION}" \
      io.datahub-r.msodbcsql.version="${MSODBCSQL_VERSION}" \
      io.datahub-r.package-lock.sha256="${PACKAGE_LOCK_SHA256}" \
      io.datahub-r.cran.repository="${PPM_REPO}"

WORKDIR /work

CMD ["R"]
