//
//  ImportExportProgressAlert.swift
//  Reynard
//
//  Created by Minh Ton on 23/10/26.
//

import UIKit

enum ImportExportProgressAlert {
    private enum UX {
        static let activityIndicatorSpacing: CGFloat = 8
    }
    
    static func run<Value>(
        from presenter: UIViewController,
        message: String,
        operation: @escaping (@escaping (Result<Value, Error>) -> Void) -> Void,
        completion: @escaping (Result<Value, Error>) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        if #available(iOS 13.0, *) {
            alert.isModalInPresentation = true
        }

        presenter.present(alert, animated: true) {
            installActivityIndicator(in: alert)
            operation { result in
                alert.dismiss(animated: true) {
                    completion(result)
                }
            }
        }
    }
    
    private static func installActivityIndicator(in alert: UIAlertController) {
        guard let message = alert.message,
              let messageLabel = alert.view.firstDescendantLabel(withText: message) else {
            return
        }
        
        let spinner: UIActivityIndicatorView = {
            if #available(iOS 13.0, *) {
                return UIActivityIndicatorView(style: .medium)
            } else {
                let indicator = UIActivityIndicatorView(style: .gray)
                indicator.color = .gray
                return indicator
            }
        }()
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
        spinner.startAnimating()
        
        let label = UILabel()
        label.font = messageLabel.font
        label.textColor = messageLabel.textColor
        label.text = message
        label.numberOfLines = 0
        
        let contentView = UIStackView(arrangedSubviews: [spinner, label])
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.axis = .horizontal
        contentView.alignment = .center
        contentView.spacing = UX.activityIndicatorSpacing
        alert.view.addSubview(contentView)
        messageLabel.textColor = .clear
        messageLabel.isAccessibilityElement = false
        
        NSLayoutConstraint.activate([
            contentView.centerXAnchor.constraint(equalTo: messageLabel.centerXAnchor),
            contentView.centerYAnchor.constraint(equalTo: messageLabel.centerYAnchor),
            contentView.leadingAnchor.constraint(greaterThanOrEqualTo: alert.view.layoutMarginsGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(lessThanOrEqualTo: alert.view.layoutMarginsGuide.trailingAnchor),
        ])
    }
}
