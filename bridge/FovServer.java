package com.glasseslab.bridge;

import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.util.*;

/** USB-started shell helper. Loopback only; no arbitrary command execution API. */
public final class FovServer {
    private static final String[] PROPS = {"debug.oculus.eyeFovUp", "debug.oculus.eyeFovDown", "debug.oculus.eyeFovInward", "debug.oculus.eyeFovOutward"};
    private static String token;
    private static String[] target;
    private static String run(String... command) throws Exception {
        Process p = new ProcessBuilder(command).redirectErrorStream(true).start();
        String out = new String(p.getInputStream().readAllBytes(), StandardCharsets.UTF_8).trim();
        if (p.waitFor() != 0) throw new IOException("Property command failed");
        return out;
    }
    private static String state() throws Exception {
        boolean on = true, off = true;
        for (int i=0;i<4;i++) {
            String value = run("/system/bin/getprop", PROPS[i]);
            on &= value.equals(target[i]); off &= value.isEmpty();
        }
        String override = run("/system/bin/getprop", "debug.oculus.headsetOverride");
        if (off && !override.equals("1")) return "OFF";
        return on && override.equals("1") ? "ON" : "CUSTOM";
    }
    private static String change(boolean enable) throws Exception {
        String[] old = new String[5];
        for(int i=0;i<4;i++) old[i] = run("/system/bin/getprop", PROPS[i]);
        old[4] = run("/system/bin/getprop", "debug.oculus.headsetOverride");
        try {
            for(int i=0;i<4;i++) run("/system/bin/setprop", PROPS[i], enable ? target[i] : "");
            run("/system/bin/setprop", "debug.oculus.headsetOverride", enable ? "1" : "0");
            String result = state();
            if (!result.equals(enable ? "ON" : "OFF")) throw new IOException("Verification failed");
            return result;
        } catch(Exception e) {
            for(int i=0;i<4;i++) run("/system/bin/setprop", PROPS[i], old[i]);
            run("/system/bin/setprop", "debug.oculus.headsetOverride", old[4]);
            throw e;
        }
    }
    private static String applyAndRefresh(boolean enable) throws Exception {
        String result = change(enable);
        // Run outside the Unity process so waking still happens while the app is paused.
        // Explicit sleep/wake keys are idempotent, unlike the power toggle key.
        boolean refreshed = false;
        try {
            run("/system/bin/input", "keyevent", "223");
            Thread.sleep(700);
            refreshed = true;
        } catch (Exception e) {
            refreshed = false;
        } finally {
            try { run("/system/bin/input", "keyevent", "224"); }
            catch (Exception e) { refreshed = false; }
        }
        return refreshed ? result : result + "_REFRESH_NEEDED";
    }
    public static void main(String[] args) throws Exception {
        List<String> config = Files.readAllLines(Paths.get(args[0]), StandardCharsets.UTF_8);
        token = config.get(0).trim();
        if(!token.matches("[a-f0-9]{64}") || config.size()!=5) throw new IOException("Invalid config");
        target = config.subList(1,5).toArray(new String[0]);
        for(String angle: target) if(!angle.matches("[0-9]+(\\.[0-9]+)?") || Float.parseFloat(angle)<=0 || Float.parseFloat(angle)>90) throw new IOException("Invalid angle");
        try(ServerSocket server = new ServerSocket()) {
            server.bind(new InetSocketAddress(InetAddress.getByName("127.0.0.1"),38667),4);
            while(true) {
                try(Socket client = server.accept()) {
                    client.setSoTimeout(2000);
                    InputStream in=client.getInputStream(); StringBuilder request=new StringBuilder();
                    for(int i=0;i<100;i++) { int c=in.read(); if(c<0||c=='\n') break; request.append((char)c); }
                    String[] parts=request.toString().trim().split(" ");
                    String result="DENIED";
                    if(parts.length==2 && MessageDigest.isEqual(token.getBytes(StandardCharsets.UTF_8),parts[0].getBytes(StandardCharsets.UTF_8))) {
                        try {
                            switch(parts[1]) {
                                case "STATUS": result=state(); break;
                                case "STATUS2": result=state(); break;
                                case "STATUS3": result=state(); break;
                                case "STATUS4":
                                    result=Arrays.equals(target, new String[]{"25","41","35","35"}) ? state() : "DENIED";
                                    break;
                                case "ON4":
                                    result=Arrays.equals(target, new String[]{"25","41","35","35"}) ? applyAndRefresh(true) : "DENIED";
                                    break;
                                case "OFF4": result=applyAndRefresh(false); break;
                                case "ON3": result=applyAndRefresh(true); break;
                                case "OFF3": result=applyAndRefresh(false); break;
                                case "ON2": result=applyAndRefresh(true); break;
                                case "OFF2": result=applyAndRefresh(false); break;
                                case "ON": result=change(true); break;
                                case "OFF": result=change(false); break;
                            }
                        } catch(Exception e) { result="ERROR"; }
                    }
                    client.getOutputStream().write((result+"\n").getBytes(StandardCharsets.UTF_8));
                } catch(IOException ignored) { }
            }
        }
    }
}
