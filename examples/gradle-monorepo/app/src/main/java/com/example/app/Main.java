package com.example.app;

import com.example.api.Greeter;

public class Main {
    public static void main(String[] args) {
        Greeter greeter = new Greeter("Hello");
        String name = args.length > 0 ? args[0] : "world";
        System.out.println(greeter.greet(name));
    }

    public static String run(String name) {
        Greeter greeter = new Greeter("Hello");
        return greeter.greet(name);
    }
}
