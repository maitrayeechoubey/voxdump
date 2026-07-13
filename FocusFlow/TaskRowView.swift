import SwiftUI
import SwiftData

struct TaskRowView: View {
    @Bindable var task: TaskItem

    private var accentColor: Color {
        switch task.urgency {
        case "high": return Color.bdRed
        case "low":  return Color.bdGreen
        default:     return Color.bdPrimary
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Urgency dot
            Circle()
                .fill(accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.bdBody())
                    .foregroundStyle(task.isCompleted ? Color.bdMuted : .white)
                    .strikethrough(task.isCompleted, color: Color.bdMuted2)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    CategoryChip(category: task.category)

                    if !task.dueLabel.isEmpty {
                        Text(task.dueLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.bdMuted)
                    }

                    if task.microSteps.count > 0 && !task.isCompleted {
                        let done = task.completedMicroStepCount
                        let total = task.microSteps.count
                        HStack(spacing: 3) {
                            ForEach(0..<total, id: \.self) { i in
                                Circle()
                                    .fill(i < done ? Color.bdGreen : Color.bdBorder)
                                    .frame(width: 5, height: 5)
                            }
                        }
                    }
                }
            }

            Spacer()

            if !task.isCompleted {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.bdMuted2)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.bdCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    task.isInProgress ? Color.bdPrimary.opacity(0.25) : Color.bdBorder,
                    lineWidth: 1
                )
        )
    }
}
