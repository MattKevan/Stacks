import Hummingbird
import StacksSync

// The sync wire models live in `StacksSync`, which the client links, so they
// stay free of any server framework. The server returns them directly and
// therefore declares the `ResponseEncodable` conformances here.
extension LibraryIdentity: ResponseEncodable {}
extension SyncPullResponse: ResponseEncodable {}
extension SyncPushResponse: ResponseEncodable {}
extension StageResponse: ResponseEncodable {}
