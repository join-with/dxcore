package com.example.api;

import com.example.core.StringUtils;

public class Greeter {
    private final String prefix;

    public Greeter(String prefix) {
        this.prefix = prefix;
    }

    public String greet(String name) {
        return prefix + " " + StringUtils.capitalize(name) + "!";
    }

    public String emphasize(String message, int level) {
        return message + StringUtils.repeat("!", level);
    }
}
