package com.example.core;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class StringUtilsTest {
    @Test
    void capitalizeNormal() {
        assertEquals("Hello", StringUtils.capitalize("hello"));
    }

    @Test
    void capitalizeEmpty() {
        assertEquals("", StringUtils.capitalize(""));
    }

    @Test
    void capitalizeNull() {
        assertNull(StringUtils.capitalize(null));
    }

    @Test
    void repeatString() {
        assertEquals("abcabcabc", StringUtils.repeat("abc", 3));
    }

    @Test
    void repeatZero() {
        assertEquals("", StringUtils.repeat("abc", 0));
    }
}
