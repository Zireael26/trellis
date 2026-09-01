// Idiomatic payload. The pattern set must stay SILENT here — every construct the
// red fixture flags appears in its justified or type-safe form.
package com.acme;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;

class Green {
    // SAFETY: the annotation claims the cast is sound; this comment is the proof.
    @SuppressWarnings("unchecked")
    private static Set<String> brands(HttpServletRequest request) {
        // SAFETY: ApiKeyAuthFilter stamps BRANDS_ATTR as a Set<String> on the bearer
        // branch only, and this method is unreachable on any other branch.
        return (Set<String>) request.getAttribute(BRANDS_ATTR);
    }

    private static String render(Money amount) {
        return amount.toPlainString();
    }

    void swallow(String raw) {
        try {
            parse(raw);
        } catch (ParseException e) {
            LOG.warn("unparseable row skipped", e);
        }
    }

    void typed() {
        Map<String, Widget> rows = new HashMap<>();
        List<Widget> items = List.copyOf(rows.values());
    }

    String unwrap(String raw) {
        return Optional.ofNullable(raw).orElseThrow(Missing::new);
    }

    void stubs() {
        when(clock.instant()).thenReturn(FIXED);
    }
}
