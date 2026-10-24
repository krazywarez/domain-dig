import Foundation

struct IPGeolocationService {
    static func lookup(ip: String) async -> ServiceResult<IPGeolocation> {
        guard let url = URL(string: "https://ipapi.co/\(ip)/json/") else {
            return .error("Not a valid IP address")
        }

        let request = URLRequest(url: url, timeoutInterval: 10)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return .error(URLError(.badServerResponse).localizedDescription)
            }

            let geolocation = try JSONDecoder().decode(IPGeolocation.self, from: data)
            return .success(geolocation)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
