use criterion::{black_box, criterion_group, criterion_main, Criterion, BenchmarkId};
use witness_gen_experiment::{generate, generate_synthetic_batch, WitnessConfig};

fn bench_witness_generation(c: &mut Criterion) {
    let config = WitnessConfig::default();

    let mut group = c.benchmark_group("witness_generation");
    group.sample_size(30);

    for size in [100, 500, 1000] {
        let batch = generate_synthetic_batch(size);
        group.bench_with_input(
            BenchmarkId::new("batch", size),
            &batch,
            |b, batch| {
                b.iter(|| generate(black_box(batch), black_box(&config)));
            },
        );
    }
    group.finish();
}

fn bench_depth_sensitivity(c: &mut Criterion) {
    let batch = generate_synthetic_batch(100);

    let mut group = c.benchmark_group("depth_sensitivity");
    group.sample_size(20);

    for depth in [32, 64, 128, 256] {
        let config = WitnessConfig { smt_depth: depth };
        group.bench_with_input(
            BenchmarkId::new("depth", depth),
            &depth,
            |b, _| {
                b.iter(|| generate(black_box(&batch), black_box(&config)));
            },
        );
    }
    group.finish();
}

criterion_group!(benches, bench_witness_generation, bench_depth_sensitivity);
criterion_main!(benches);
