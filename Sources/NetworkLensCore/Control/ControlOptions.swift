//
//  ControlOptions.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 30/08/26.
//

import Foundation

/// Where the control channel collects commands, and how often.
public struct ControlOptions: Sendable {

    /// Loopback only — see `LensControlChannel` for why the app polls rather than listening.
    public var endpoint: URL

    /// Two seconds matches the browser lens, and is the budget an agent's round trip already spends.
    public var pollInterval: TimeInterval

    /// A queue grown past this is one nobody drained; replaying it all would flip rules through states no one asked to see.
    public var maxCommandsPerPoll: Int

    public init(
        endpoint: URL = ControlOptions.defaultEndpoint,
        pollInterval: TimeInterval = 2,
        maxCommandsPerPoll: Int = 20
    ) {
        self.endpoint = endpoint
        self.pollInterval = pollInterval
        self.maxCommandsPerPoll = maxCommandsPerPoll
    }

    /// Hosted by the `networklens` MCP server, which an MCP client launches on its own — so a fresh
    /// clone is live with nothing extra installed. Not 8787: that is the browser sidecar's, and taking
    /// it would send the extension's trace ingest into a 404.
    public static let defaultEndpoint: URL = {
        guard let url = URL(string: "http://127.0.0.1:8788") else {
            return URL(fileURLWithPath: "/")
        }
        return url
    }()
}
