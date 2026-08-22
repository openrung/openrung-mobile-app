import Foundation

public struct ClientGeoInfo: Sendable, Equatable {
    public let ip: String
    public let country: String
    public let countryCode: String
    public let city: String
    public let asn: String
    public let isp: String
    public let organization: String

    public init(
        ip: String,
        country: String,
        countryCode: String,
        city: String,
        asn: String,
        isp: String,
        organization: String
    ) {
        self.ip = ip
        self.country = country
        self.countryCode = countryCode
        self.city = city
        self.asn = asn
        self.isp = isp
        self.organization = organization
    }

    public func telemetryAttributes() -> [String: String] {
        [
            "client_ip": ip,
            "country": country,
            "country_code": countryCode,
            "city": city,
            "asn": asn,
            "isp": isp,
            "organization": organization,
        ].filter { $0.value.isEmpty == false }
    }
}

public enum GeoIpError: Error, Equatable {
    case httpStatus(Int)
    case lookupFailed
}

/// Looks up geo information for the caller's own public IP via ipwho.is.
/// Port of Android `GeoIpClient`.
public struct GeoIpClient: Sendable {
    public static let defaultEndpoint = URL(string: "https://ipwho.is/")!

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL = GeoIpClient.defaultEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Looks up geo info for the caller's own public IP.
    public func lookup() async throws -> ClientGeoInfo {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            throw GeoIpError.httpStatus(http.statusCode)
        }
        return try GeoIpClient.decode(data)
    }

    static func decode(_ data: Data) throws -> ClientGeoInfo {
        let response = try JSONDecoder().decode(GeoIpResponse.self, from: data)
        guard response.success, response.ip.isEmpty == false else {
            throw GeoIpError.lookupFailed
        }
        return ClientGeoInfo(
            ip: response.ip,
            country: response.country,
            countryCode: response.countryCode,
            city: response.city,
            asn: response.asn > 0 ? "AS\(response.asn)" : "",
            isp: response.isp,
            organization: response.org
        )
    }
}

private struct GeoIpResponse: Decodable {
    let ip: String
    let success: Bool
    let country: String
    let countryCode: String
    let city: String
    let asn: Int
    let org: String
    let isp: String

    enum CodingKeys: String, CodingKey {
        case ip, success, country, city, connection
        case countryCode = "country_code"
    }

    enum ConnectionKeys: String, CodingKey {
        case asn, org, isp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ip = (try? container.decode(String.self, forKey: .ip)) ?? ""
        success = (try? container.decode(Bool.self, forKey: .success)) ?? false
        country = (try? container.decode(String.self, forKey: .country)) ?? ""
        countryCode = (try? container.decode(String.self, forKey: .countryCode)) ?? ""
        city = (try? container.decode(String.self, forKey: .city)) ?? ""

        if let connection = try? container.nestedContainer(keyedBy: ConnectionKeys.self, forKey: .connection) {
            asn = (try? connection.decode(Int.self, forKey: .asn)) ?? 0
            org = (try? connection.decode(String.self, forKey: .org)) ?? ""
            isp = (try? connection.decode(String.self, forKey: .isp)) ?? ""
        } else {
            asn = 0
            org = ""
            isp = ""
        }
    }
}
