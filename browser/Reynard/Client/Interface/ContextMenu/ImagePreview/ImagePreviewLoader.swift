//
//  ImagePreviewLoader.swift
//  Reynard
//
//  Created by Minh Ton on 16/6/26.
//

import GeckoView
import UIKit

struct ImagePreviewLoader {
    // Upstream routes through Gecko networking (authenticated images + WebP),
    // kept here in completion style.
    static func image(from url: URL, in session: GeckoSession, completion: @escaping (UIImage?) -> Void) {
        if url.isFileURL {
            let image = UIImage(contentsOfFile: url.path)
            DispatchQueue.main.async {
                completion(image)
            }
            return
        }

        if url.scheme?.lowercased() == "data" {
            let image = imageFromDataURL(url.absoluteString)
            DispatchQueue.main.async {
                completion(image)
            }
            return
        }
        session.fetchImageData(from: url) { data in
            let image = data.flatMap { UIImage(data: $0) }
            DispatchQueue.main.async {
                completion(image)
            }
        }
    }
    
    private static func imageFromDataURL(_ value: String) -> UIImage? {
        guard let commaIndex = value.firstIndex(of: ",") else {
            return nil
        }
        
        let payload = value[value.index(after: commaIndex)...]
        let data: Data?
        if value[..<commaIndex].lowercased().contains(";base64") {
            data = Data(base64Encoded: String(payload))
        } else {
            data = String(payload).removingPercentEncoding?.data(using: .utf8)
        }
        
        guard let data else {
            return nil
        }
        return UIImage(data: data)
    }
}
