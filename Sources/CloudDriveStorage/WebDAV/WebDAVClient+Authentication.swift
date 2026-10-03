import Foundation
import CloudDriveContracts
import CloudDriveSupport

extension WebDAVClient {
    func addAuthentication(to request: inout URLRequest) {
        if let credentials = credentials, let user = credentials.user, let password = credentials.password {
            request.setValue("Basic " + Data("\(user):\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        }
    }

    /// 创建目录（MKCOL）- 支持递归创建父目录
}
