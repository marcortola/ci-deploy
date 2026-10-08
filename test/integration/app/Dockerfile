# A tiny HTTP application: answers its name and the running Kamal version. HEALTH=fail builds an
# image whose health check never passes; FAIL_BUILD=1 makes the build itself fail.
FROM busybox:1.36
ARG FAIL_BUILD=0
ARG HEALTH=ok
RUN [ "$FAIL_BUILD" != 1 ]
RUN mkdir -p /www && if [ "$HEALTH" = ok ]; then echo ok > /www/up; fi
ENV APP_NAME=app
EXPOSE 3000
CMD ["sh", "-c", "echo \"$APP_NAME $KAMAL_VERSION\" > /www/index.html && exec httpd -f -p 3000 -h /www"]
