// The test-set coverage gate (CI plan C19, D11; run by .claude/scripts/test-set-coverage.sh, never on its own).
//
// build.gradle.kts skips a slow test set (integrationTest, startupTest, resourceTest) when no compiled test class of the
// module holds the set's tag name as bytes (PR #113). That scan is cheap but blind to a tag that reaches a test only
// through a type compiled elsewhere: a meta-annotation, a superclass or an interface from another module, or an
// enclosing class of a @Nested test. This program reads the compiled classes with the JDK's class-file API, works out
// each test's real JUnit tags the way JUnit does (@Tag and @Tags, directly or as meta-annotations, on the class, its
// superclasses, its interfaces, the enclosing class of a @Nested class, and on the test method), and fails when a module
// has a test with a set's tag while the build's scan would skip that set. Test class names play no part.
//
// Usage: java test-set-coverage.java <root> --set <task>=<tag>... [--module <name>...]
// Every <root>/<module>/build/classes/java/{main,test,testFixtures} is read to resolve types across modules; the
// modules checked are the ones named, or every <root>/<module> with a src/test/java. Exit 0 ok, 1 a FAIL line, 2 usage.

import java.io.IOException;
import java.lang.classfile.Annotation;
import java.lang.classfile.AnnotationValue;
import java.lang.classfile.Attributes;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.MethodModel;
import java.lang.classfile.constantpool.ClassEntry;
import java.lang.reflect.AccessFlag;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Stream;

public class TestSetCoverage {
    static final String TAG = "org/junit/jupiter/api/Tag";
    static final String TAGS = "org/junit/jupiter/api/Tags";
    static final String NESTED = "org/junit/jupiter/api/Nested";
    static final String TESTABLE = "org/junit/platform/commons/annotation/Testable";
    // The JUnit annotations that make a method a test; each is @Testable, which a custom one may also carry.
    static final Set<String> TEST_ANNOTATIONS = Set.of(
            "org/junit/jupiter/api/Test", "org/junit/jupiter/api/RepeatedTest", "org/junit/jupiter/api/TestFactory",
            "org/junit/jupiter/api/TestTemplate", "org/junit/jupiter/params/ParameterizedTest", TESTABLE);

    record Ann(String type, List<String> tags) {}
    record Method(String key, List<Ann> anns) {}
    record Info(String name, String module, boolean testDir, String superName, List<String> interfaces, boolean isAbstract,
                boolean isInterface, boolean isAnnotation, List<Ann> anns, List<Method> methods, String outer) {}

    final Map<String, List<Info>> index = new HashMap<>();
    final Map<String, Map<String, String>> classTagMemo = new HashMap<>();

    public static void main(String[] args) throws IOException {
        if (args.length < 1) usage("no root");
        Path root = Path.of(args[0]);
        Map<String, String> sets = new LinkedHashMap<>();
        List<String> modules = new ArrayList<>();
        for (int i = 1; i < args.length; i++) {
            String a = args[i];
            if (i + 1 >= args.length) usage("missing value after " + a);
            String v = args[++i];
            switch (a) {
                case "--set" -> {
                    int eq = v.indexOf('=');
                    if (eq <= 0 || eq == v.length() - 1) usage("--set wants <task>=<tag>, got " + v);
                    sets.put(v.substring(0, eq), v.substring(eq + 1));
                }
                case "--module" -> modules.add(v);
                default -> usage("unknown argument " + a);
            }
        }
        if (sets.isEmpty()) usage("no --set");
        System.exit(new TestSetCoverage().run(root, sets, modules));
    }

    static void usage(String why) {
        System.err.println("test-set-coverage: " + why);
        System.err.println("usage: java test-set-coverage.java <root> --set <task>=<tag>... [--module <name>...]");
        System.exit(2);
    }

    int run(Path root, Map<String, String> sets, List<String> modules) throws IOException {
        try (Stream<Path> dirs = Files.list(root)) {
            for (Path m : dirs.filter(Files::isDirectory).sorted().toList()) {
                for (String kind : List.of("main", "testFixtures", "test")) {
                    Path classes = m.resolve("build/classes/java").resolve(kind);
                    if (Files.isDirectory(classes)) read(classes, m.getFileName().toString(), kind.equals("test"));
                }
            }
        }
        if (modules.isEmpty()) {
            try (Stream<Path> dirs = Files.list(root)) {
                modules = dirs.filter(m -> Files.isDirectory(m.resolve("src/test/java")))
                        .map(m -> m.getFileName().toString()).sorted().toList();
            }
        }
        int fails = 0;
        int classes = 0;
        for (String module : modules) {
            Path testSrc = root.resolve(module).resolve("src/test/java");
            Path testOut = root.resolve(module).resolve("build/classes/java/test");
            if (!Files.isDirectory(testOut)) {
                if (hasJava(testSrc)) {
                    System.out.println("FAIL: " + module + ": has test sources but no compiled test classes in "
                            + root.relativize(testOut) + " (compile them first: testClasses)");
                    fails++;
                }
                continue;
            }
            List<Info> tests = new ArrayList<>();
            index.values().forEach(l -> l.stream().filter(c -> c.testDir() && c.module().equals(module)).forEach(tests::add));
            tests.sort((a, b) -> a.name().compareTo(b.name()));
            classes += tests.size();
            for (Map.Entry<String, String> set : sets.entrySet()) {
                String tag = set.getValue();
                if (scanFinds(testOut, tag)) continue;
                for (Info c : tests) {
                    String via = testWithTag(c, tag);
                    if (via != null) {
                        System.out.println("FAIL: " + module + ": " + set.getKey() + " would be skipped, but "
                                + c.name().replace('/', '.') + " has a test tagged " + tag + " (" + via
                                + "), which no class file of the module names");
                        fails++;
                        break;
                    }
                }
            }
        }
        if (fails > 0) return 1;
        System.out.println("test-set-coverage: ok (" + modules.size() + " modules, " + classes + " test classes, sets "
                + String.join(" ", sets.keySet()) + ")");
        return 0;
    }

    static boolean hasJava(Path dir) throws IOException {
        if (!Files.isDirectory(dir)) return false;
        try (Stream<Path> s = Files.walk(dir)) {
            return s.anyMatch(p -> p.toString().endsWith(".java"));
        }
    }

    // The build's own test (build.gradle.kts onlyIf): a class file of the module holds the tag's name as bytes.
    static boolean scanFinds(Path testOut, String tag) throws IOException {
        try (Stream<Path> s = Files.walk(testOut)) {
            for (Path p : s.filter(f -> f.toString().endsWith(".class")).toList()) {
                if (new String(Files.readAllBytes(p), StandardCharsets.ISO_8859_1).contains(tag)) return true;
            }
        }
        return false;
    }

    void read(Path dir, String module, boolean testDir) throws IOException {
        List<Path> files;
        try (Stream<Path> s = Files.walk(dir)) {
            files = s.filter(f -> f.toString().endsWith(".class")).toList();
        }
        for (Path f : files) {
            ClassModel cm = ClassFile.of().parse(Files.readAllBytes(f));
            String name = cm.thisClass().asInternalName();
            if (name.endsWith("module-info") || name.endsWith("package-info")) continue;
            String outer = cm.findAttribute(Attributes.innerClasses()).flatMap(ic -> ic.classes().stream()
                    .filter(i -> i.innerClass().asInternalName().equals(name)).findFirst()
                    .flatMap(i -> i.outerClass()).map(ClassEntry::asInternalName)).orElse(null);
            List<Method> methods = new ArrayList<>();
            for (MethodModel mm : cm.methods()) {
                methods.add(new Method(mm.methodName().stringValue() + mm.methodType().stringValue(),
                        anns(mm.findAttribute(Attributes.runtimeVisibleAnnotations()).map(a -> a.annotations()))));
            }
            Info info = new Info(name, module, testDir, cm.superclass().map(ClassEntry::asInternalName).orElse(null),
                    cm.interfaces().stream().map(ClassEntry::asInternalName).toList(),
                    cm.flags().has(AccessFlag.ABSTRACT), cm.flags().has(AccessFlag.INTERFACE),
                    cm.flags().has(AccessFlag.ANNOTATION),
                    anns(cm.findAttribute(Attributes.runtimeVisibleAnnotations()).map(a -> a.annotations())), methods, outer);
            index.computeIfAbsent(name, k -> new ArrayList<>()).add(info);
        }
    }

    static List<Ann> anns(Optional<List<Annotation>> list) {
        List<Ann> out = new ArrayList<>();
        for (Annotation a : list.orElse(List.of())) out.add(new Ann(internal(a), tagsOf(a)));
        return out;
    }

    static String internal(Annotation a) {
        String d = a.classSymbol().descriptorString();
        return d.substring(1, d.length() - 1);
    }

    // The tag values an annotation itself carries: @Tag("x"), or @Tags({@Tag("x"), ...}).
    static List<String> tagsOf(Annotation a) {
        List<String> tags = new ArrayList<>();
        String type = internal(a);
        for (var e : a.elements()) {
            if (!e.name().stringValue().equals("value")) continue;
            if (type.equals(TAG) && e.value() instanceof AnnotationValue.OfString s) tags.add(s.stringValue().strip());
            if (type.equals(TAGS) && e.value() instanceof AnnotationValue.OfArray arr) {
                for (AnnotationValue v : arr.values()) {
                    if (v instanceof AnnotationValue.OfAnnotation n) tags.addAll(tagsOf(n.annotation()));
                }
            }
        }
        return tags;
    }

    Info lookup(String name, String module) {
        List<Info> l = index.get(name);
        if (l == null || l.isEmpty()) return null;
        return l.stream().filter(i -> i.module().equals(module)).findFirst().orElse(l.get(0));
    }

    // tag -> where it comes from, for a list of annotations, following meta-annotations.
    void annTags(List<Ann> anns, String module, String where, Map<String, String> out, Set<String> seen) {
        for (Ann a : anns) {
            for (String t : a.tags()) out.putIfAbsent(t, "@Tag on " + where);
            if (a.type().startsWith("java/lang/annotation/") || !seen.add(a.type())) continue;
            Info def = lookup(a.type(), module);
            if (def != null) annTags(def.anns(), def.module(), "meta-annotation " + simple(a.type()) + " of " + where, out, seen);
        }
    }

    boolean isTest(List<Ann> anns, String module, Set<String> seen) {
        for (Ann a : anns) {
            if (TEST_ANNOTATIONS.contains(a.type())) return true;
            if (a.type().startsWith("java/lang/annotation/") || !seen.add(a.type())) continue;
            Info def = lookup(a.type(), module);
            if (def != null && isTest(def.anns(), def.module(), seen)) return true;
        }
        return false;
    }

    // The tags a class carries for JUnit: its own and meta tags, its superclasses', its interfaces', and, for a @Nested
    // class, its enclosing class's.
    Map<String, String> classTags(Info c) {
        Map<String, String> memo = classTagMemo.get(c.name() + "@" + c.module());
        if (memo != null) return memo;
        Map<String, String> out = new LinkedHashMap<>();
        classTagMemo.put(c.name() + "@" + c.module(), out); // a cycle reads what is there so far
        annTags(c.anns(), c.module(), simple(c.name()), out, new HashSet<>());
        List<String> supers = new ArrayList<>();
        if (c.superName() != null) supers.add(c.superName());
        supers.addAll(c.interfaces());
        boolean nested = c.anns().stream().anyMatch(a -> a.type().equals(NESTED));
        if (nested && c.outer() != null) supers.add(c.outer());
        for (String s : supers) {
            Info si = lookup(s, c.module());
            if (si == null) continue;
            String rel = s.equals(c.outer()) ? "enclosing class " : si.isInterface() ? "interface " : "superclass ";
            String mod = si.module().equals(c.module()) ? "" : " in " + si.module();
            classTags(si).forEach((t, w) -> out.putIfAbsent(t, w + " via " + rel + simple(s) + mod));
        }
        return out;
    }

    // Null, or how a runnable test of the class gets the tag (its class's tags plus the test method's own).
    String testWithTag(Info c, String tag) {
        if (c.isAbstract() || c.isInterface() || c.isAnnotation()) return null;
        Map<String, String> ct = classTags(c);
        Set<String> seenKeys = new TreeSet<>();
        Set<String> walked = new HashSet<>();
        List<Info> todo = new ArrayList<>(List.of(c));
        while (!todo.isEmpty()) {
            Info k = todo.remove(0);
            if (!walked.add(k.name())) continue;
            for (Method m : k.methods()) {
                if (!seenKeys.add(m.key())) continue; // overridden lower down: that one decides
                if (!isTest(m.anns(), k.module(), new HashSet<>())) continue;
                if (ct.containsKey(tag)) return ct.get(tag);
                Map<String, String> mt = new LinkedHashMap<>();
                annTags(m.anns(), k.module(), "method " + simple(k.name()) + "." + m.key().substring(0, m.key().indexOf('(')), mt, new HashSet<>());
                if (mt.containsKey(tag)) return mt.get(tag) + (k == c ? "" : " in " + k.module());
            }
            List<String> up = new ArrayList<>();
            if (k.superName() != null) up.add(k.superName());
            up.addAll(k.interfaces());
            for (String s : up) {
                Info si = lookup(s, k.module());
                if (si != null) todo.add(si);
            }
        }
        return null;
    }

    static String simple(String internal) {
        return internal.substring(internal.lastIndexOf('/') + 1);
    }
}
