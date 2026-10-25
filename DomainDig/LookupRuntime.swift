import Foundation

/// Opted out of the project's MainActor default isolation: this is a plain
/// value pair constructed inside `actor LookupRuntime`, and a MainActor-bound
/// memberwise init cannot be called from there under Swift 6.
nonisolated struct CachedLookupResult<Value> {
    let value: Value
    let source: LookupResultSource
}

/// Opting out of MainActor isolation also opted out of the implicit
/// Sendable that globally-isolated types get, which is what lets this cross
/// from `actor LookupRuntime` back to its callers.
extension CachedLookupResult: Sendable where Value: Sendable {}

actor LookupRuntime {
    static let shared = LookupRuntime()

    private let ttl: TimeInterval = 300

    enum RequestKey: Hashable {
        case domain(String, LookupSectionKind)
        case subject(String, LookupSectionKind)
    }

    enum RateLimitBucket: Hashable {
        case crtsh
        case rdap
        case ipGeolocation

        var minimumSpacing: TimeInterval {
            switch self {
            case .crtsh:
                return 1.0
            case .rdap:
                return 0.75
            case .ipGeolocation:
                return 0.75
            }
        }
    }

    private struct CacheEntry {
        let value: any Sendable
        let expiresAt: Date
    }

    private var cache: [RequestKey: CacheEntry] = [:]
    private var inFlight: [RequestKey: Task<any Sendable, Never>] = [:]
    private var nextAllowedAt: [RateLimitBucket: Date] = [:]

    func clearCache() {
        cache.removeAll()
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        nextAllowedAt.removeAll()
    }

    func dns(domain: String) async -> CachedLookupResult<ServiceResult<[DNSSection]>> {
        await execute(
            key: .domain(domain, .dns),
            operation: {
                await DNSLookupService.lookupAll(domain: domain)
            }
        )
    }

    func availability(domain: String, allowsRDAP: Bool) async -> CachedLookupResult<DomainAvailabilityResult> {
        CachedLookupResult(
            value: await DomainAvailabilityService.check(domain: domain, allowsRDAP: allowsRDAP),
            source: .live
        )
    }

    func ssl(domain: String) async -> CachedLookupResult<ServiceResult<SSLCertificateInfo>> {
        await execute(
            key: .domain(domain, .ssl),
            operation: {
                await SSLCheckService.check(domain: domain)
            }
        )
    }

    func hsts(domain: String) async -> CachedLookupResult<Bool?> {
        await execute(
            key: .domain(domain, .hsts),
            operation: {
                await SSLCheckService.checkHSTSPreload(domain: domain)
            }
        )
    }

    func http(domain: String) async -> CachedLookupResult<ServiceResult<HTTPHeadersResult>> {
        await execute(
            key: .domain(domain, .httpHeaders),
            operation: {
                await HTTPHeadersService.fetch(domain: domain)
            }
        )
    }

    func reachability(domain: String) async -> CachedLookupResult<ServiceResult<[PortReachability]>> {
        await execute(
            key: .domain(domain, .reachability),
            operation: {
                await ReachabilityService.checkAll(domain: domain)
            }
        )
    }

    func ownership(domain: String) async -> CachedLookupResult<ServiceResult<DomainOwnership>> {
        await execute(
            key: .domain(domain, .ownership),
            rateLimitBucket: .rdap,
            operation: {
                await DomainOwnershipService.lookup(domain: domain)
            }
        )
    }

    func redirectChain(domain: String) async -> CachedLookupResult<ServiceResult<[RedirectHop]>> {
        await execute(
            key: .domain(domain, .redirectChain),
            operation: {
                await RedirectChainService.trace(domain: domain)
            }
        )
    }

    func subdomains(domain: String) async -> CachedLookupResult<ServiceResult<[DiscoveredSubdomain]>> {
        await execute(
            key: .domain(domain, .subdomains),
            rateLimitBucket: .crtsh,
            operation: {
                await SubdomainDiscoveryService.discover(for: domain)
            }
        )
    }

    func portScan(domain: String) async -> CachedLookupResult<ServiceResult<[PortScanResult]>> {
        await execute(
            key: .domain(domain, .portScan),
            operation: {
                await PortScanService.scanAll(domain: domain)
            }
        )
    }

    func email(domain: String, txtRecords: [DNSRecord]) async -> CachedLookupResult<ServiceResult<EmailSecurityResult>> {
        await execute(
            key: .domain(domain, .emailSecurity),
            operation: {
                await EmailSecurityService.analyze(domain: domain, txtRecords: txtRecords)
            }
        )
    }

    func ptr(ip: String, resolverURLString: String) async -> CachedLookupResult<ServiceResult<String>> {
        await execute(
            key: .subject("\(resolverURLString)|\(ip)", .ptr),
            operation: {
                await ReverseDNSService.lookup(ip: ip, resolverURLString: resolverURLString)
            }
        )
    }

    func ipGeolocation(ip: String) async -> CachedLookupResult<ServiceResult<IPGeolocation>> {
        await execute(
            key: .subject(ip, .ipGeolocation),
            rateLimitBucket: .ipGeolocation,
            operation: {
                await IPGeolocationService.lookup(ip: ip)
            }
        )
    }

    func suggestions(domain: String) async -> CachedLookupResult<[DomainSuggestionResult]> {
        await execute(
            key: .domain(domain, .suggestions),
            operation: {
                await DomainAvailabilityService.suggestions(for: domain)
            }
        )
    }

    func execute<T: Sendable>(
        key: RequestKey,
        rateLimitBucket: RateLimitBucket? = nil,
        operation: @escaping @Sendable () async -> T
    ) async -> CachedLookupResult<T> {
        if let cachedEntry = cache[key], cachedEntry.expiresAt > Date(), let value = cachedEntry.value as? T {
            return CachedLookupResult(value: value, source: .cached)
        }

        if let task = inFlight[key], let value = await task.value as? T {
            return CachedLookupResult(value: value, source: .mixed)
        }

        let task = Task<T, Never> {
            if let rateLimitBucket {
                await self.enforceRateLimit(for: rateLimitBucket)
            }
            return await operation()
        }
        // `inFlight` can only hold the erased task, and cancelling that erased
        // wrapper does not reach the work it is waiting on. `clearCache()`
        // cancels what is in flight, so the wrapper forwards cancellation.
        inFlight[key] = Task {
            await withTaskCancellationHandler {
                await task.value as any Sendable
            } onCancel: {
                task.cancel()
            }
        }

        let value = await task.value
        cache[key] = CacheEntry(value: value, expiresAt: Date().addingTimeInterval(ttl))
        inFlight[key] = nil

        return CachedLookupResult(value: value, source: .live)
    }

    private func enforceRateLimit(for bucket: RateLimitBucket) async {
        let now = Date()
        if let nextAllowed = nextAllowedAt[bucket], nextAllowed > now {
            let delay = nextAllowed.timeIntervalSince(now)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        nextAllowedAt[bucket] = Date().addingTimeInterval(bucket.minimumSpacing)
    }
}
