FROM alpine:3.24

RUN apk add --no-cache \
        ca-certificates \
        curl \
        iproute2 \
        iproute2-tc \
        iproute2-ss \
        iptables \
        jq \
        nftables \
        openssl \
        libqrencode-tools \
        tini \
        tzdata \
        unzip \
    && update-ca-certificates

RUN mkdir -p \
        /etc/rysh \
        /usr/local/bin \
        /usr/local/etc/xray \
        /usr/local/xray \
        /usr/local/share/rysh \
        /usr/local/share/xray \
        /usr/share/rysh \
        /var/log/xray

ENV RYSH_XRAY_BIN=/usr/local/xray/xray

COPY rysh.sh /usr/local/bin/rysh
COPY container-entrypoint.sh /usr/local/bin/container-entrypoint
COPY sni-candidates.tsv sni-risk-suffixes.txt /usr/share/rysh/

RUN chmod 755 /usr/local/bin/rysh /usr/local/bin/container-entrypoint \
    && ln -sf /usr/local/bin/rysh /usr/local/bin/ry \
    && chmod 644 /usr/share/rysh/sni-candidates.tsv /usr/share/rysh/sni-risk-suffixes.txt

VOLUME ["/etc/rysh", "/usr/local/etc/xray", "/usr/local/xray", "/usr/local/share/xray", "/usr/local/share/rysh", "/var/log/xray"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/rysh", "health"]

STOPSIGNAL SIGTERM
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/container-entrypoint"]
