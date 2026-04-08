package com.example.core;

public class StringUtils {
    public static String capitalize(String input) {
        if (input == null || input.isEmpty()) {
            return input;
        }
        return input.substring(0, 1).toUpperCase() + input.substring(1);
    }

    public static String repeat(String input, int count) {
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < count; i++) {
            sb.append(input);
        }
        return sb.toString();
    }
}
