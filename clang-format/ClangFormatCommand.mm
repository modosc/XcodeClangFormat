#import "ClangFormatCommand.h"

#include <clang/Format/Format.h>

@implementation ClangFormatCommand

- (NSData*)getCustomStyle {
    // First, read the regular bookmark because it could've been changed by the wrapper app.
    NSData* regularBookmark = [defaults dataForKey:@"regularBookmark"];
    NSURL* regularURL = nil;
    BOOL regularStale = NO;
    if (regularBookmark) {
        regularURL = [NSURL URLByResolvingBookmarkData:regularBookmark
                                               options:NSURLBookmarkResolutionWithoutUI
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&regularStale
                                                 error:nil];
    }

    if (!regularURL) {
        return nil;
    }

    // Then read the security URL, which is the URL we're actually going to use to access the file.
    NSData* securityBookmark = [defaults dataForKey:@"securityBookmark"];
    NSURL* securityURL = nil;
    BOOL securityStale = NO;
    if (securityBookmark) {
        securityURL = [NSURL
            URLByResolvingBookmarkData:securityBookmark
                               options:NSURLBookmarkResolutionWithSecurityScope | NSURLBookmarkResolutionWithoutUI
                         relativeToURL:nil
                   bookmarkDataIsStale:&securityStale
                                 error:nil];
    }

    // Clear out the security URL if it's no longer matching the regular URL.
    if (securityStale == YES || (securityURL && ![[securityURL path] isEqualToString:[regularURL path]])) {
        securityURL = nil;
    }

    if (!securityURL && regularStale == NO) {
        // Attempt to create new security URL from the regular URL to persist across system reboots.
        NSError* error = nil;
        securityBookmark = [regularURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope |
                                                               NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
                                includingResourceValuesForKeys:nil
                                                 relativeToURL:nil
                                                         error:&error];
        [defaults setObject:securityBookmark forKey:@"securityBookmark"];
        securityURL = regularURL;
    }

    if (securityURL) {
        // Finally, attempt to read the .clang-format file
        NSError* error = nil;
        [securityURL startAccessingSecurityScopedResource];
        NSData* data = [NSData dataWithContentsOfURL:securityURL options:0 error:&error];
        [securityURL stopAccessingSecurityScopedResource];
        if (error) {
            NSLog(@"Error loading from security bookmark: %@", error);
        } else if (data) {
            return data;
        }
    }

    return nil;
}

std::vector<clang::tooling::Range> computeOffsets(NSMutableArray<NSString*>* lines) {
    size_t offset = 0;
    auto output = std::vector<clang::tooling::Range>();
    output.reserve([lines count]);
    for (NSString* line in lines) {
        output.emplace_back(offset, line.length);
        offset += line.length;
    }

    return output;
}

size_t lineFromOffset(const std::vector<clang::tooling::Range>& offsets, unsigned offset) {
    const auto it = std::find_if(offsets.cbegin(), offsets.cend(), [offset](const clang::tooling::Range& lineOffset) {
        return offset >= lineOffset.getOffset() && offset < lineOffset.getOffset() + lineOffset.getLength();
    });
    return std::distance(offsets.cbegin(), it);
}

size_t columnFromOffset(const std::vector<clang::tooling::Range>& offsets, unsigned offset) {
    const auto line = lineFromOffset(offsets, offset);
    return offset - offsets[line].getOffset();
}

NSErrorDomain errorDomain = @"ClangFormatError";
NSUserDefaults* defaults = nil;

- (BOOL)setFormatWithStyle:(NSString*)style format:(clang::format::FormatStyle*)format {
    format->Language = clang::format::FormatStyle::LK_Cpp;
    clang::format::getPredefinedStyle("LLVM", format->Language, format);

    if ([style isEqualToString:@"custom"]) {
        NSData* config = [self getCustomStyle];
        if (!config) {
            return NO;
        } else {
            // parse style
            llvm::StringRef configString(reinterpret_cast<const char*>(config.bytes), config.length);
            auto error = clang::format::parseConfiguration(configString, format);
            if (error) {
                return NO;
            }
        }
    } else {
        auto success =
            clang::format::getPredefinedStyle(llvm::StringRef([style cStringUsingEncoding:NSUTF8StringEncoding]),
                                              clang::format::FormatStyle::LanguageKind::LK_Cpp, format);
        if (!success) {
            return NO;
        }
    }

    return YES;
}

- (void)performCommandWithInvocation:(XCSourceEditorCommandInvocation*)invocation
                   completionHandler:(void (^)(NSError* _Nullable nilOrError))completionHandler {
    if (!defaults) {
        defaults = [[NSUserDefaults alloc] initWithSuiteName:@"XcodeClangFormat"];
    }

    NSString* style = [defaults stringForKey:@"style"];
    if (!style) {
        style = @"llvm";
    }

    clang::format::FormatStyle format = clang::format::getLLVMStyle();
    const BOOL success = [self setFormatWithStyle:style format:&format];
    if (success != YES) {
        completionHandler([NSError
            errorWithDomain:errorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Could not set style: %@", style]
                   }]);
        return;
    }

    // Retrieve buffer and its offsets
    auto code = llvm::StringRef([invocation.buffer.completeBuffer UTF8String]);
    auto offsets = computeOffsets(invocation.buffer.lines);

    // Force range to full buffer
    auto ranges = std::vector<clang::tooling::Range>();
    ranges.emplace_back(0, code.size());

    auto replaces = clang::format::reformat(format, code, ranges);

    if (format.SortIncludes) {
        auto includeSort = clang::format::sortIncludes(format, code, ranges, "tmp");
        for (auto& repl : includeSort) {
            replaces.add(repl);
        }
    }
    if (replaces.empty()) {
        completionHandler([NSError
            errorWithDomain:errorDomain
                       code:0
                   userInfo:@{
                       NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Style %@ already OK", style]
                   }]);
        return;
    }

    auto result = clang::tooling::applyAllReplacements(code, replaces);
    if (!result) {
        // We could not apply the calculated replacements.
        completionHandler([NSError
            errorWithDomain:errorDomain
                       code:0
                   userInfo:@{NSLocalizedDescriptionKey : @"Failed to apply formatting replacements."}]);
        return;
    }

    // Copy selections as they probably be destroyed when setting the buffer
    NSArray<XCSourceTextRange*>* selections =
        [[NSArray alloc] initWithArray:invocation.buffer.selections copyItems:YES];
    [invocation.buffer.selections removeAllObjects];

    invocation.buffer.completeBuffer =
        [[NSString alloc] initWithBytes:result->data() length:result->length() encoding:NSUTF8StringEncoding];

    const auto offsetsNew = computeOffsets(invocation.buffer.lines);

    // Re-create selections
    for (XCSourceTextRange* range in selections) {
        auto start = offsets[range.start.line].getOffset() + (int) range.start.column;
        auto end = offsets[range.end.line].getOffset() + (int) range.end.column;

        start = replaces.getShiftedCodePosition(start);
        end = replaces.getShiftedCodePosition(end);

        const auto start_line = lineFromOffset(offsetsNew, start);
        const auto start_column = columnFromOffset(offsetsNew, start);
        const auto end_line = lineFromOffset(offsetsNew, end);
        const auto end_column = columnFromOffset(offsetsNew, end);

        [invocation.buffer.selections
            addObject:[[XCSourceTextRange alloc] initWithStart:XCSourceTextPositionMake(start_line, start_column)
                                                           end:XCSourceTextPositionMake(end_line, end_column)]];
    }

    // If we could not recover any selection, place the cursor at the beginning of the file.
    if (invocation.buffer.selections.count == 0) {
        [invocation.buffer.selections
            addObject:[[XCSourceTextRange alloc] initWithStart:XCSourceTextPositionMake(0, 0)
                                                           end:XCSourceTextPositionMake(0, 0)]];
    }

    completionHandler(nil);
    return;
}
@end
