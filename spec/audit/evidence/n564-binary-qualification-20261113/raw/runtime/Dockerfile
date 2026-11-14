FROM ubuntu:24.04
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl libssl3 libgcc-s1 && rm -rf /var/lib/apt/lists/*
COPY rnode /usr/local/bin/rnode
ENTRYPOINT ["rnode"]
