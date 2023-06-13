FROM openjdk:11
RUN mkdir -p /app
WORKDIR /app
VOLUME /app
EXPOSE 8080
ARG JAR=dangnyang-1.7.08-SNAPSHOT.jar
COPY ../../build/libs/${JAR} /app/koboot.jar
ENTRYPOINT ["nohup", "java","-Dspring.profiles.active=prod","-jar","/app/koboot.jar", "&"]