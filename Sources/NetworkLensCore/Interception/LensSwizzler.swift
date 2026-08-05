//
//  LensSwizzler.swift
//  NetworkLensCore
//
//  Created by Rohit Sahay on 29/07/26.
//

import Foundation
import ObjectiveC

/// Method swizzling for zero-config installation.
///
/// Every hook is guarded by a `static let`, which Swift initialises exactly
/// once and lazily. Double-swizzling is not a no-op — it restores the original
/// implementation and silently disables everything, which presents as "the tool
/// stopped working" with no error anywhere.
public enum LensSwizzler {

    // MARK: - URLSessionConfiguration

    private static let configurationHooks: Void = {
        exchangeClassMethod(
            on: URLSessionConfiguration.self,
            original: #selector(getter: URLSessionConfiguration.default),
            replacement: #selector(getter: URLSessionConfiguration.lens_default)
        )
        exchangeClassMethod(
            on: URLSessionConfiguration.self,
            original: #selector(getter: URLSessionConfiguration.ephemeral),
            replacement: #selector(getter: URLSessionConfiguration.lens_ephemeral)
        )
    }()

    public static func installConfigurationHooks() {
        _ = configurationHooks
    }

    // MARK: - URLSession task creation

    private static let taskHooks: Void = {
        let pairs: [(Selector, Selector)] = [
            (#selector(URLSession.dataTask(with:) as (URLSession) -> (URLRequest) -> URLSessionDataTask),
             #selector(URLSession.lens_dataTask(with:) as (URLSession) -> (URLRequest) -> URLSessionDataTask)),
            (#selector(URLSession.dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask),
             #selector(URLSession.lens_dataTask(with:completionHandler:) as (URLSession) -> (URLRequest, @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask)),
            (#selector(URLSession.uploadTask(with:from:) as (URLSession) -> (URLRequest, Data) -> URLSessionUploadTask),
             #selector(URLSession.lens_uploadTask(with:from:) as (URLSession) -> (URLRequest, Data?) -> URLSessionUploadTask)),
            (#selector(URLSession.uploadTask(with:fromFile:) as (URLSession) -> (URLRequest, URL) -> URLSessionUploadTask),
             #selector(URLSession.lens_uploadTask(with:fromFile:) as (URLSession) -> (URLRequest, URL) -> URLSessionUploadTask)),
            (#selector(URLSession.downloadTask(with:) as (URLSession) -> (URLRequest) -> URLSessionDownloadTask),
             #selector(URLSession.lens_downloadTask(with:) as (URLSession) -> (URLRequest) -> URLSessionDownloadTask)),
        ]
        for (original, replacement) in pairs {
            exchangeInstanceMethod(on: URLSession.self, original: original, replacement: replacement)
        }
    }()

    public static func installTaskHooks() {
        _ = taskHooks
    }

    // MARK: - Primitives

    private static func exchangeInstanceMethod(
        on klass: AnyClass, original: Selector, replacement: Selector
    ) {
        guard let originalMethod = class_getInstanceMethod(klass, original),
              let replacementMethod = class_getInstanceMethod(klass, replacement) else {
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// Class methods live on the metaclass, so `class_getClassMethod` is
    /// required — `class_getInstanceMethod` silently finds nothing here.
    private static func exchangeClassMethod(
        on klass: AnyClass, original: Selector, replacement: Selector
    ) {
        guard let originalMethod = class_getClassMethod(klass, original),
              let replacementMethod = class_getClassMethod(klass, replacement) else {
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

// MARK: - Configuration hooks

extension URLSessionConfiguration {

    /// After the exchange, this body runs as `.default`, and the call inside it
    /// reaches the original getter.
    @objc class var lens_default: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.lens_default
        NetworkLens.install(into: configuration, adoptingForPassthrough: false)
        return configuration
    }

    @objc class var lens_ephemeral: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.lens_ephemeral
        NetworkLens.install(into: configuration, adoptingForPassthrough: false)
        return configuration
    }
}

// MARK: - Task creation hooks

extension URLSession {

    /// Screen attribution has to be read here, synchronously, on whatever
    /// thread the app called from.
    ///
    /// `@TaskLocal` does not work for this — it does not propagate across the
    /// `URLSession` callback boundary — and by the time `canInit` runs we may
    /// be on the session's delegate queue, which has no relationship to the
    /// caller.
    private func lens_stamp(_ request: URLRequest) -> URLRequest {
        guard NetworkLens.isActive else { return request }
        return request.stamped(screen: ScreenContext.shared.current, exchangeID: UUID())
    }

    @objc func lens_dataTask(with request: URLRequest) -> URLSessionDataTask {
        lens_dataTask(with: lens_stamp(request))
    }

    @objc func lens_dataTask(
        with request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        lens_dataTask(with: lens_stamp(request), completionHandler: completionHandler)
    }

    @objc func lens_uploadTask(with request: URLRequest, from data: Data?) -> URLSessionUploadTask {
        lens_uploadTask(with: lens_stamp(request), from: data)
    }

    @objc func lens_uploadTask(with request: URLRequest, fromFile url: URL) -> URLSessionUploadTask {
        lens_uploadTask(with: lens_stamp(request), fromFile: url)
    }

    @objc func lens_downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        lens_downloadTask(with: lens_stamp(request))
    }
}
