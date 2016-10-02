//
//  XMLTemplateService.swift
//  TemplateKit
//
//  Created by Matias Cudich on 9/11/16.
//  Copyright © 2016 Matias Cudich. All rights reserved.
//

import Foundation

class XMLTemplateParser: Parser {
  typealias ParsedType = XMLElement

  required init() {}

  func parse(data: Data) throws -> XMLElement {
    return try XMLDocumentParser(data: data).parse()
  }
}

class StyleSheetParser: Parser {
  typealias ParsedType = String

  required init() {}

  func parse(data: Data) -> String {
    return String(data: data, encoding: .utf8) ?? ""
  }
}

public class XMLTemplateService: TemplateService {
  public var cachePolicy: CachePolicy {
    set {
      templateResourceService.cachePolicy = newValue
    }
    get {
      return templateResourceService.cachePolicy
    }
  }

  public var liveReloadInterval = DispatchTimeInterval.seconds(5)

  let templateResourceService = ResourceService<XMLTemplateParser>()
  let styleSheetResourceService = ResourceService<StyleSheetParser>()

  private let liveReload: Bool
  private lazy var cache = [URL: Template]()
  private lazy var observers = [URL: NSHashTable<AnyObject>]()

  public init(liveReload: Bool = false) {
    self.liveReload = liveReload
  }

  public func element(withLocation location: URL, model: Model) throws -> Element {
    guard let element = try cache[location]?.makeElement(with: model) else {
      throw TemplateKitError.missingTemplate("Template not found for \(location)")
    }
    return element
  }

  public func fetchTemplates(withURLs urls: [URL], completion: @escaping (Result<Void>) -> Void) {
    var expectedCount = urls.count
    if cachePolicy == .never {
      URLCache.shared.removeAllCachedResponses()
    }
    for url in urls {
      templateResourceService.load(url) { [weak self] result in
        expectedCount -= 1
        switch result {
        case .success(let templateXML):
          guard let componentElement = templateXML.componentElement else {
            completion(.failure(TemplateKitError.parserError("No component element found in template at \(url)")))
            return
          }

          self?.resolveStyles(for: templateXML, at: url) { styleSheet in
            self?.cache[url] = Template(elementProvider: componentElement, styleSheet: styleSheet)
            if expectedCount == 0 {
              completion(.success())
              if self?.liveReload ?? false {
                self?.watchTemplates(withURLs: urls)
              }
            }
          }
        case .failure(_):
          completion(.failure(TemplateKitError.missingTemplate("Template not found at \(url)")))
        }
      }
    }
  }

  public func addObserver(observer: Node, forLocation location: URL) {
    if !liveReload {
      return
    }
    let observers = self.observers[location] ?? NSHashTable.weakObjects()

    observers.add(observer as AnyObject)
    self.observers[location] = observers
  }

  public func removeObserver(observer: Node, forLocation location: URL) {
    observers[location]?.remove(observer as AnyObject)
  }

  private func resolveStyles(for template: XMLElement, at relativeURL: URL, completion: @escaping (StyleSheet?) -> Void) {
    var urls = [URL]()
    var sheets = [String](repeating: "", count: template.styleElements.count)
    for (index, styleElement) in template.styleElements.enumerated() {
      if let urlString = styleElement.attributes["url"], let url = URL(string: urlString, relativeTo: relativeURL) {
        urls.append(url)
      } else {
        sheets[index] = styleElement.value ?? ""
      }
    }

    let done = { (fetchedSheets: [String]) in
      completion(StyleSheet(string: fetchedSheets.joined()))
    }

    var expectedCount = urls.count
    if expectedCount == 0 {
      return done(sheets)
    }

    for (index, url) in urls.enumerated() {
      styleSheetResourceService.load(url) { result in
        expectedCount -= 1
        switch result {
        case .success(let sheetString):
          sheets[index] = sheetString
          if expectedCount == 0 {
            done(sheets)
          }
        case .failure(_):
          done(sheets)
        }
      }
    }
  }

  private func watchTemplates(withURLs urls: [URL]) {
    let time = DispatchTime.now() + liveReloadInterval
    DispatchQueue.main.asyncAfter(deadline: time) {
      let cachedCopies = self.cache
      self.fetchTemplates(withURLs: urls) { [weak self] result in
        for url in urls {
          if self?.cache[url] != cachedCopies[url], let observers = self?.observers[url] {
            for observer in observers.allObjects {
              (observer as! Node).forceUpdate()
            }
          }
        }
      }
    }
  }
}

extension XMLElement: ElementProvider {
  var hasRemoteStyles: Bool {
    return styleElements.contains { element in
      return element.attributes["url"] != nil
    }
  }

  var styleElements: [XMLElement] {
    return children.filter { candidate in
      return candidate.name == "style"
    }
  }

  var componentElement: XMLElement? {
    return children.first { candidate in
      return candidate.name != "style"
    }
  }

  func makeElement(with model: Model) throws -> Element {
    let resolvedProperties = model.resolve(properties: attributes)
    return NodeRegistry.shared.buildElement(with: name, properties: resolvedProperties, children: try children.map { try $0.makeElement(with: model) })
  }
}
