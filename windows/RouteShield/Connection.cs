using System.Net;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;

namespace RouteShield;

internal sealed record Addresses(IPAddress? IPv4, IPAddress? IPv6)
{
    internal bool Empty => IPv4 is null && IPv6 is null;
}

internal sealed class AddressBaseline
{
    private IPAddress? ipv4;
    private IPAddress? ipv6;

    internal void Reset() => ipv4 = ipv6 = null;

    internal bool Changed(IPAddress? sample)
    {
        if (sample is null) return false;
        ref IPAddress? known = ref (sample.AddressFamily == AddressFamily.InterNetwork ? ref ipv4 : ref ipv6);
        bool changed = known is not null && !known.Equals(sample);
        known = sample;
        return changed;
    }
}

internal sealed class Connection : IDisposable
{
    private readonly HttpClient ipv4 = CreateProbeClient(AddressFamily.InterNetwork);
    private readonly HttpClient ipv6 = CreateProbeClient(AddressFamily.InterNetworkV6);
    private readonly HttpClient country = new() { Timeout = TimeSpan.FromSeconds(4) };
    private readonly Dictionary<IPAddress, (string Code, DateTimeOffset Expiry)> countries = new();

    private static HttpClient CreateProbeClient(AddressFamily family) => new(new SocketsHttpHandler
    {
        UseProxy = false,
        PooledConnectionLifetime = TimeSpan.Zero,
        ConnectCallback = async (context, token) =>
        {
            var socket = new Socket(family, SocketType.Stream, ProtocolType.Tcp);
            try
            {
                var endpoint = new DnsEndPoint(context.DnsEndPoint.Host, context.DnsEndPoint.Port, family);
                await socket.ConnectAsync(endpoint, token).ConfigureAwait(false);
                return new NetworkStream(socket, ownsSocket: true);
            }
            catch
            {
                socket.Dispose();
                throw;
            }
        }
    }) { Timeout = TimeSpan.FromSeconds(4) };

    internal async Task<IPAddress?> Probe(AddressFamily family, CancellationToken token)
    {
        try
        {
            string text = await (family == AddressFamily.InterNetwork
                ? ipv4.GetStringAsync("https://api.ipify.org", token)
                : ipv6.GetStringAsync("https://ifconfig.me/ip", token));
            return IPAddress.TryParse(text.Trim(), out var address) &&
                   address.AddressFamily == family && !address.IsIPv4MappedToIPv6 ? address : null;
        }
        catch (Exception error) when (error is HttpRequestException || error is OperationCanceledException)
        {
            token.ThrowIfCancellationRequested();
            return null;
        }
    }

    internal async Task<Addresses> Read(CancellationToken token)
    {
        var four = Probe(AddressFamily.InterNetwork, token);
        var six = Probe(AddressFamily.InterNetworkV6, token);
        await Task.WhenAll(four, six);
        return new(await four, await six);
    }

    internal async Task<(string? IPv4, string? IPv6)> Countries(Addresses addresses, CancellationToken token)
    {
        var four = Country(addresses.IPv4, token);
        var six = Country(addresses.IPv6, token);
        await Task.WhenAll(four, six);
        return (await four, await six);
    }

    private async Task<string?> Country(IPAddress? address, CancellationToken token)
    {
        if (address is null) return null;
        if (countries.TryGetValue(address, out var cached) && cached.Expiry > DateTimeOffset.UtcNow)
            return cached.Code;

        try
        {
            var result = await country.GetFromJsonAsync<JsonElement>($"https://api.country.is/{address}", token);
            if (result.ValueKind != JsonValueKind.Object || !result.TryGetProperty("country", out var value) ||
                value.ValueKind != JsonValueKind.String) return null;
            string? code = value.GetString();
            if (code is null || code.Length != 2 || !code.All(char.IsAsciiLetterUpper)) return null;
            if (countries.Count >= 128) countries.Clear();
            countries[address] = (code, DateTimeOffset.UtcNow.AddHours(1));
            return code;
        }
        catch (Exception error) when (error is HttpRequestException || error is JsonException || error is OperationCanceledException)
        {
            token.ThrowIfCancellationRequested();
            return null;
        }
    }

    public void Dispose()
    {
        ipv4.Dispose();
        ipv6.Dispose();
        country.Dispose();
    }
}
