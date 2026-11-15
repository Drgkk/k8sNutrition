FROM eclipse-temurin:25-jdk-jammy AS build
RUN apt-get update && apt-get install -y --no-install-recommends curl unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /workspace
COPY app/ ./
RUN bash ./gradlew --no-daemon bootJar

FROM eclipse-temurin:25-jre-jammy
ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION}
RUN useradd --system --uid 10001 --create-home appuser
WORKDIR /app
COPY --from=build --chown=appuser /workspace/build/libs/nutrition-api.jar /app/app.jar
USER appuser
EXPOSE 8181
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
