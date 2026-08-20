FROM broadinstitute/gatk:4.6.2.0

USER root

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        samtools \
        hisat2 \
        bash \
        coreutils \
        findutils \
        gawk \
        grep \
        sed \
        gzip \
        bzip2 \
        ca-certificates \
        procps \
        file \
        pigz \
        curl \
        wget \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /opt/rna-mutect

COPY pipeline.sh /opt/rna-mutect/pipeline.sh
COPY entrypoint.sh /opt/rna-mutect/entrypoint.sh

RUN chmod 755 /opt/rna-mutect/pipeline.sh && \
    chmod 755 /opt/rna-mutect/entrypoint.sh

ENV PATH="/opt/rna-mutect:${PATH}"

WORKDIR /data

ENTRYPOINT ["/opt/rna-mutect/entrypoint.sh"]
