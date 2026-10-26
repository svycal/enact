Application.put_env(:enact, :rate_limiter, EnactTest.FakeRateLimiter)

ExUnit.start()
