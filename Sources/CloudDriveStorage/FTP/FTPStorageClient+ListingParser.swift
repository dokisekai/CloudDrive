import Foundation
import CloudDriveContracts
import CloudDriveSupport
import Network
import UniformTypeIdentifiers

extension FTPStorageClient {
    // MARK: - FTP Directory Listing Parser
    
    func parseFTPList(_ listText: String, basePath: String) -> [StorageResource] {
        var results: [StorageResource] = []
        let lines = listText.components(separatedBy: CharacterSet.newlines)
        let cleanBase = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let prefix = cleanBase.isEmpty ? "" : "/\(cleanBase)"
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("total") { continue }
            
            // UNIX 格式: drwxr-xr-x 2 user group 4096 Oct 02 12:00 myfolder
            let isDir = trimmed.hasPrefix("d")
            let parts = trimmed.components(separatedBy: CharacterSet.whitespaces).filter { !$0.isEmpty }
            if parts.count >= 9 {
                let name = parts[8...].joined(separator: " ")
                if name == "." || name == ".." { continue }
                let size = isDir ? 0 : (Int64(parts[4]) ?? 0)
                let itemPath = "\(prefix)/\(name)"
                
                results.append(StorageResource(
                    path: itemPath,
                    displayName: name,
                    isDirectory: isDir,
                    contentLength: size,
                    contentType: isDir ? nil : UTType(filenameExtension: (name as NSString).pathExtension)?.identifier
                ))
            } else if parts.count >= 4 {
                // DOS 格式: 01-15-26 01:23PM <DIR> myfolder 或 01-15-26 01:23PM 1234 myfile.txt
                let isDOSDir = parts.contains("<DIR>")
                let name = parts.last ?? ""
                if name.isEmpty || name == "." || name == ".." { continue }
                let size = isDOSDir ? 0 : (Int64(parts[2]) ?? 0)
                let itemPath = "\(prefix)/\(name)"
                
                results.append(StorageResource(
                    path: itemPath,
                    displayName: name,
                    isDirectory: isDOSDir,
                    contentLength: size,
                    contentType: isDOSDir ? nil : UTType(filenameExtension: (name as NSString).pathExtension)?.identifier
                ))
            }
        }
        return results
    }
}
