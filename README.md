# Flume

![Test](https://github.com/scripbox/flume/workflows/CI/badge.svg?branch=master&event=push)

Flume is a job processing system backed by [GenStage](https://github.com/elixir-lang/gen_stage) & [Redis](https://redis.io/)

## Table of Contents

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
  - [Pipelines](#pipelines)
  - [Enqueuing Jobs](#enqueuing-jobs)
  - [Creating Workers](#creating-workers)
  - [Scheduled Jobs](#scheduled-jobs)
  - [Rate Limiting](#rate-limiting)
  - [Batch Processing](#batch-processing)
  - [Pipeline Control](#pipeline-control)
  - [Instrumentation](#instrumentation)
- [Writing Tests](#writing-tests)
- [Roadmap](#roadmap)
- [References](#references)
- [Contributing](#contributing)

## Features

- **Durability** - Jobs are backed up before processing. Incase of crashes, these
  jobs are restored.
- **Back-pressure** - Uses [gen_stage](https://github.com/elixir-lang/gen_stage) to support this.
- **Scheduled Jobs** - Jobs can be scheduled to run at any point in future.
- **Rate Limiting** - Uses redis to maintain rate-limit on pipelines.
- **Batch Processing** - Jobs are grouped based on size.
- **Logging** - Provides a behaviour `Flume.Logger` to define your own logger module.
- **Pipeline Control** - Queues can be pause/resume at runtime.
- **Instrumentation** - Metrics like worker duration and latency to fetch jobs from redis are emitted via [telemetry](https://github.com/beam-telemetry/telemetry).
- **Exponential Back-off** - On failure, jobs are retried with exponential back-off. Minimum and maximum can be set via configuration.

## Requirements

- Elixir 1.6.6+
- Erlang/OTP 21.1+
- Redis 4.0+

## Installation

Add Flume to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:flume, github: "scripbox/flume"}
  ]
end
```

Then run `mix deps.get` to install Flume and its dependencies.

## Usage

Add Flume supervisor to your application's supervision tree:

```elixir
defmodule MyApplication.Application do
  use Application

  import Supervisor.Spec

  def start(_type, _args) do
    children = [
      # Start Flume supervisor
      supervisor(Flume, [])
    ]

    opts = [strategy: :one_for_one, name: MyApplication.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

Add `config/flume.exs`:

```elixir
config :flume,
  name: Flume,
  # Redis host
  host: "127.0.0.1",
  # Redis port
  port: "6379",
  # Redis keys namespace
  namespace: "my-app",
  # Redis database
  database: 0,
  # Redis pool size
  redis_pool_size: 10,
  # Redis connection timeout in ms (Default 5000 ms)
  redis_timeout: 10_000,
  # Retry backoff intial in ms (Default 500 ms)
  backoff_initial: 30_000,
  # Retry backoff maximum in ms (Default 10_000 ms)
  backoff_max: 36_00_000,
  # Maximum number of retries (Default 5)
  max_retries: 15,
  # Scheduled jobs poll interval in ms (Default 10_000 ms)
  scheduler_poll_interval: 10_000,
  # Time to move jobs from processing queue to retry queue in seconds (Default 600 sec)
  visibility_timeout: 600,
  # ttl of the acquired lock to fetch jobs for bulk pipelines in ms (Default 30_000 ms)
  dequeue_lock_ttl: 30_000,
  # process timeout to fetch jobs for bulk pipelines in ms (Default 10_000 ms)
  dequeue_process_timeout: 10_000,
  # time to poll the queue again if it was locked by another process in ms (Default 500 ms)
  dequeue_lock_poll_interval: 500
```

Import flume config in `config/config.exs` as given below:

```elixir
...
import_config "#{Mix.env()}.exs"
+import_config "flume.exs"
```

### Pipelines

Each pipeline is a GenStage pipeline having these parameters -

* `name` - Name of the pipeline
* `queue` - Name of the Redis queue to pull jobs from
* `max_demand` - Maximum number of jobs to pull from the queue

**Configuration**

```elixir
config :flume,
  pipelines: [
    %{name: "default_pipeline", queue: "default", max_demand: 1000},
  ]
```

Flume supervisor will start these processes:

```asciidoc
                  [Flume.Supervisor]   <- (Supervisor)
                         |
                         |
                         |
              [default_pipeline_producer]   <- (Producer)
                         |
                         |
                         |
          [default_pipeline_producer_consumer]   <- (ProducerConsumer)
                         |
                         |
                         |
         [default_pipeline_consumer_supervisor]   <- (ConsumerSupervisor)
                        / \
                       /   \
                      /     \
             [worker_1]     [worker_2]   <- (Worker Processes)
```

### Enqueuing Jobs

Enqueuing jobs into flume requires these things -

* Specify a `queue-name` (like `priority`)
* Specify the worker module (`MyApp.FancyWorker`)
* Specify the worker module's function name (default `:perform`)
* Specify the arguments as per the worker module's function arity

**With default function**

```elixir
Flume.enqueue(:queue_name, MyApp.FancyWorker, [arg_1, arg_2])
```

**With custom function**

```elixir
Flume.enqueue(:queue_name, MyApp.FancyWorker, :myfunc, [arg_1, arg_2])
```

### Creating Workers

Worker modules are responsible for processing a job.
A worker module should define the `function-name` with the exact arity used while queuing the job.

```elixir
defmodule MyApp.FancyWorker do
  def perform(arg_1, arg_2) do
    # your job processing logic
  end
end
```

### Scheduled Jobs

**With default function**

```elixir
# 10 seconds
schedule_time = 10

Flume.enqueue_in(:queue_name, schedule_time, MyApp.FancyWorker, [arg_1, arg_2])
```

**With custom function**

```elixir
# 10 seconds
schedule_time = 10

Flume.enqueue_in(:queue_name, schedule_time, MyApp.FancyWorker, :myfunc, [arg_1, arg_2])
```

### Rate Limiting

Flume supports rate-limiting for each configured pipeline.

Rate-Limiting has two key parameters -

- `rate_limit_scale` - Time scale in `milliseconds` for the pipeline
- `rate_limit_count` - Total number of jobs to be processed within the time scale
- `rate_limit_key`(optional) - Using this option, rate limit can be set across pipelines.

       **Note**: When this option is not set, rate limit will be maintained for a pipeline.

```elixir
rate_limit_count = 1000
rate_limit_scale = 6 * 1000

config :flume,
  pipelines: [
    # This pipeline will process 1000 jobs every 6 seconds
    %{
      name: "promotional_email_pipeline",
      queue: "promotional_email",
      rate_limit_count: rate_limit_count,
      rate_limit_scale: rate_limit_scale,
      rate_limit_key: "email"
    },
    %{
      name: "transactional_email_pipeline",
      queue: "transactional_email",
      rate_limit_count: rate_limit_count,
      rate_limit_scale: rate_limit_scale,
      rate_limit_key: "email"
    }
  ]

OR

config :flume
  pipelines: [
    %{
      name: "webhooks_pipeline",
      queue: "webhooks",
      rate_limit_count: 1000,
      rate_limit_scale: 5000
    }
  ]
```

Flume will process the configured number of jobs (`rate_limit_count`) for each rate-limited pipeline,
even if we are running multiple instances of our application.

### Batch Processing

Flume supports batch-processing for each configured pipeline.
It groups individual jobs by the configured `batch_size` option and
each worker process will receive a group of jobs.

```elixir
config :flume,
  pipelines: [
    # This pipeline will pull (100 * 10) jobs from the queue
    # and group them in batches of 10.
    %{
      name: "batch_pipeline",
      queue: "batch-queue",
      max_demand: 100,
      batch_size: 10
    }
  ]
```

```elixir
defmodule MyApp.BatchWorker do
  def perform(args) do
    # args will be a list of arguments
    # E.g - [[job_1_args], [job_2_args], ...]
    # your job processing logic
  end
end
```

### Pipeline Control

Flume has support to pause/resume each pipeline.
Once a pipeline is paused, the producer process will stop pulling jobs from the queue.
It will process the jobs which are already pulled from the queue.

Refer to "Options" section for supported options and default values.

**Pause all pipelines**
```elixir
# Pause all pipelines permanently (in Redis) and asynchronously
Flume.pause_all(temporary: false, async: true)
```

**Pause a pipeline**

```elixir
# Pause a pipeline temporarily (in current node) and asynchronously
Flume.pause(:default_pipeline, temporary: true, async: true)
```

**Resume all pipelines**
```elixir
# Resume all pipelines temporarily (in current node) and synchronously with infinite timeout
Flume.resume_all(temporary: true, async: false, timeout: :infinity)
```

**Resume a pipeline**

```elixir
# Resume a pipeline permanently (in Redis) and synchronously with a 10000 milli-second timeout
Flume.resume(:default_pipeline, temporary: false, async: false, timeout: 10000)
```

#### Options
The following options can be used to pause/resume a pipeline
  * `:async` - (boolean) Defaults to `false`.
      * `true` - The caller will not wait for the operation to complete.
      * `false` - The caller will wait for the operation to complete, this can lead to timeout if the operation takes too long to succeed. See https://hexdocs.pm/elixir/GenServer.html#call/3 for more details.
  * `:temporary` - (boolean) Defaults to `true`.
      * `true` - The pause/resume operation will be applied only on the current node.
      * `false` - Will update the value in persistent-store (Redis) and will apply the operation on all nodes.
  * `:timeout` - (timeout) Defaults to `5000`. Timeout(in milliseconds) for synchronous pause/resume calls. See https://hexdocs.pm/elixir/GenServer.html#call/3-timeouts for more details.

### Instrumentation

We use [telemetry](https://github.com/beam-telemetry/telemetry) to emit metrics.
Following metrics are emitted:

- duration of a job/worker
- count, latency and payload_size of dequeued jobs

## Writing Tests

**To enable mock in the test environment**

**config/test.exs**

```elixir
config :flume, mock: true
```

**To mock individual test**

```elixir
import Flume.Mock
...
describe "enqueue/4" do
  test "mock works" do
    with_flume_mock do
      Flume.enqueue(:test, List, :last, [[1]])

      assert_receive %{
        queue: :test,
        worker: List,
        function_name: :last,
        args: [[1]]
      }
    end
  end
end
```

**To enable mock for all tests in a module**

```elixir
defmodule ListTest do
  use ExUnit.Case, async: true
  use Flume.Mock

  describe "enqueue/4" do
    test "mock works" do
      Flume.enqueue(:test, List, :last, [[1]])

      assert_receive %{
        queue: :test,
        worker: List,
        function_name: :last,
        args: [[1]]
      }
    end
  end
end
```

## Roadmap

* Support multiple queue backends (right now only Redis is supported)

## References

* Background Processing in Elixir with GenStage (https://medium.com/@scripbox_tech/background-processing-in-elixir-with-genstage-efb6cb8ca94a)

## Contributing

* Check formatting (`mix format --check-formatted`)
* Run all tests (`mix test`)
