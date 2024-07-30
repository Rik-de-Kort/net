FROM alpine:latest
WORKDIR /app
COPY zig-out/bin/04_udp /app/04_udp
RUN chmod +x /app/04_udp
CMD ["./04_udp"]
