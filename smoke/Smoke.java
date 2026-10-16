import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.stream.IntStream;

/**
 * The CI's check of an Android runtime on an emulator, run by its launcher: the VM starts, its JIT compiles hot code,
 * threads, the time zones and the file system work. Prints "smoke ok" on standard output (the VM's own output goes to
 * standard error).
 */
public class Smoke {
    public static void main(String[] args) throws Exception {
        // Hot enough for the JIT to compile it
        long sum = 0;
        for (int round = 0; round < 200; round++) {
            sum += IntStream.range(0, 100_000).filter(i -> i % 7 == 3).asLongStream().sum();
        }
        var pool = Executors.newFixedThreadPool(4);
        var counts = new ConcurrentHashMap<Integer, Integer>();
        for (int i = 0; i < 1000; i++) {
            int key = i % 10;
            pool.execute(() -> counts.merge(key, 1, Integer::sum));
        }
        pool.shutdown();
        if (!pool.awaitTermination(1, TimeUnit.MINUTES)) throw new IllegalStateException("threads");
        if (counts.values().stream().mapToInt(Integer::intValue).sum() != 1000) throw new IllegalStateException("counts");
        if (sum != 200L * IntStream.range(0, 100_000).filter(i -> i % 7 == 3).asLongStream().sum()) throw new IllegalStateException("sum");
        var zone = java.time.ZoneId.of("Asia/Jerusalem").getRules().getOffset(java.time.Instant.EPOCH);
        var tmp = java.nio.file.Files.createTempFile("smoke", ".txt");
        java.nio.file.Files.writeString(tmp, "ok");
        System.err.println(System.getProperty("java.vm.name") + " " + System.getProperty("java.version") + " "
            + System.getProperty("os.arch") + ", Jerusalem at the epoch " + zone);
        System.out.println("smoke " + java.nio.file.Files.readString(tmp));
    }
}
