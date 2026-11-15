package com.example.nutrition.controller;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class VersionController {
    private final String version;
    private final String pod;

    public VersionController(
            @Value("${app.version:v1}") String version,
            @Value("${HOSTNAME:local}") String pod) {
        this.version = version;
        this.pod = pod;
    }

    @GetMapping({"/", "/api/version"})
    public VersionInfo version() {
        String message = "v2".equals(version)
                ? "Nutrition API v2 — welcome to the updated version!"
                : "Nutrition API v1 — welcome!";
        return new VersionInfo(version, message, pod);
    }

    public record VersionInfo(String version, String message, String pod) {
    }
}
