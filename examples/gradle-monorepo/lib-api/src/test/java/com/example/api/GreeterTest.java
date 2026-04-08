package com.example.api;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class GreeterTest {
    @Test
    void greetCapitalizes() {
        Greeter greeter = new Greeter("Hello");
        assertEquals("Hello World!", greeter.greet("world"));
    }

    @Test
    void emphasizeAddsExclamation() {
        Greeter greeter = new Greeter("Hi");
        assertEquals("wow!!!", greeter.emphasize("wow", 3));
    }
}
