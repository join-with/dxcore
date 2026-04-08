package com.example.app;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class MainTest {
    @Test
    void runGreetsWithCapitalizedName() {
        assertEquals("Hello World!", Main.run("world"));
    }

    @Test
    void runHandlesAlreadyCapitalized() {
        assertEquals("Hello Alice!", Main.run("Alice"));
    }
}
