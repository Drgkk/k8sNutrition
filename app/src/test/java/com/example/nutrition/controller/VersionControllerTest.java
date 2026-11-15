package com.example.nutrition.controller;

import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class VersionControllerTest {
    @ParameterizedTest
    @CsvSource({
            "v1, Nutrition API v1 — welcome!",
            "v2, Nutrition API v2 — welcome to the updated version!"
    })
    void identifiesTheVersionAndServingPodOnBothRoutes(String version, String message) throws Exception {
        var mvc = MockMvcBuilders.standaloneSetup(new VersionController(version, "demo-pod")).build();
        for (String path : new String[]{"/", "/api/version"}) {
            mvc.perform(get(path))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.version").value(version))
                    .andExpect(jsonPath("$.message").value(message))
                    .andExpect(jsonPath("$.pod").value("demo-pod"));
        }
    }
}
