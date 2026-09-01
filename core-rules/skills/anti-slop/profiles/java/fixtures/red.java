// Deliberate-slop payload. Every row of the java pattern set must fire here.
// Carved out from real scans by the **/fixtures/** glob.
package com.acme;

import java.util.*;

class Red {
    @SuppressWarnings("unchecked")
    private static Set<String> brands(HttpServletRequest request) {
        return (Set<String>) request.getAttribute(BRANDS_ATTR);
    }

    private static String str(Object value) {
        return value == null ? null : value.toString();
    }

    static String pick(String key, Object value) {
        return key + value;
    }

    void swallow(String raw) {
        try { parse(raw); } catch (ParseException e) {}
    }

    void shout(Exception e) {
        e.printStackTrace();
    }

    void raw() {
        Map rows = new HashMap();
        List items = new ArrayList();
    }

    void reflect() throws Exception {
        Widget.class.getDeclaredField("id").setAccessible(true);
        Widget.class.getDeclaredMethod("hidden");
    }

    String unwrap(String raw) {
        return Optional.ofNullable(raw).get();
    }

    void mocks() {
        mockStatic(Clock.class);
        Mockito.mock(Ledger.class);
    }
}
