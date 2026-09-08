ARG BASE_IMAGE
FROM ${BASE_IMAGE}

ARG BASE_IMAGE
ARG R_VERSION
ARG FREETDS_VERSION=1.3.17+ds-2build3
ARG PPM_REPO

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=UTC \
    R_VERSION=${R_VERSION} \
    R_LIBS_SITE=/opt/rdh/site-library \
    RDH_PPM_REPO=${PPM_REPO}

# The fully specified Posit tag fixes the R patch version while allowing the
# image publisher to rebuild that tag with OS and security updates.
RUN case "$(dpkg --print-architecture)" in \
        amd64|arm64) ;; \
        *) echo "unsupported image architecture: $(dpkg --print-architecture)" >&2; exit 1 ;; \
    esac \
    && test "$(Rscript -e 'cat(as.character(getRversion()))')" = "${R_VERSION}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        gfortran \
        git \
        libcurl4-openssl-dev \
        libicu-dev \
        libssl-dev \
        libxml2-dev \
        locales \
        make \
        pkg-config \
        "tdsodbc=${FREETDS_VERSION}" \
        unixodbc \
        unixodbc-dev \
    && rm -rf /var/lib/apt/lists/* \
    && odbcinst -q -d | grep -Fx '[FreeTDS]'

RUN install -d -o root -g root -m 0755 \
        /opt/rdh \
        /opt/rdh/site-library

COPY pkg.lock /opt/rdh/pkg.lock
COPY container/install-locked.R /opt/rdh/install-locked.R

# Bootstrap pak through PPM, then install every direct and transitive package at
# the exact version in the committed lock. The installer also writes a manifest
# and fails if the installed library and lock disagree.
RUN Rscript -e 'options(repos = c(CRAN = Sys.getenv("RDH_PPM_REPO"))); install.packages("pak", lib = Sys.getenv("R_LIBS_SITE"), dependencies = NA)' \
    && Rscript /opt/rdh/install-locked.R

COPY VERSION /opt/rdh/VERSION
COPY container/Rprofile.site "/opt/R/${R_VERSION}/lib/R/etc/Rprofile.site"
COPY container/database.R /opt/rdh/database.R
COPY container/check.R /opt/rdh/check.R
COPY container/smoke.R /opt/rdh/smoke.R
COPY container/test-connection.R /opt/rdh/test-connection.R

ARG RDH_VERSION

# VERSION is the release-version authority. The build caller supplies the same
# value as an argument so OCI metadata cannot silently drift from the checkout.
RUN test -n "${RDH_VERSION}" \
    && test "$(tr -d '\r\n' < /opt/rdh/VERSION)" = "${RDH_VERSION}"

RUN chmod -R a=rX /opt/rdh \
    && Rscript /opt/rdh/smoke.R

# Build metadata belongs to the OCI labels and does not invalidate dependency layers.
ARG BUILD_DATE=unknown
ARG VCS_REF=uncommitted
ARG PACKAGE_LOCK_SHA256=unknown

LABEL org.opencontainers.image.title="rdh" \
      org.opencontainers.image.description="Portable R environment for database work" \
      org.opencontainers.image.version="${RDH_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      io.rdh.r.version="${R_VERSION}" \
      io.rdh.freetds.version="${FREETDS_VERSION}" \
      io.rdh.package-lock.sha256="${PACKAGE_LOCK_SHA256}" \
      io.rdh.cran.repository="${PPM_REPO}"

WORKDIR /work

CMD ["R"]
