import { z } from 'zod';

export const currentUserSchema = z.object({
  id: z.string().uuid(),
  email: z.string().email(),
  name: z.string(),
  locale: z.string(),
  createdAt: z.string(),
});

export const organizationSchema = z.object({
  id: z.string().uuid(),
  name: z.string(),
  slug: z.string(),
  description: z.string().nullable().optional(),
  createdAt: z.string().optional(),
});

export const organizationListSchema = z.object({
  data: z.array(organizationSchema),
});

export const projectSchema = z.object({
  id: z.string().uuid(),
  organizationId: z.string().uuid(),
  name: z.string(),
  key: z.string(),
  description: z.string().nullable(),
  createdAt: z.string(),
});

export const projectListSchema = z.object({
  data: z.array(projectSchema),
});

export const issueSchema = z.object({
  id: z.string().uuid(),
  projectId: z.string().uuid(),
  workflowKey: z.string(),
  workflowRepoId: z.string().uuid().nullable(),
  number: z.number(),
  title: z.string(),
  description: z.string().nullable(),
  currentState: z.string(),
  assigneeId: z.string().uuid().nullable(),
  assigneeName: z.string().nullable(),
  reporterId: z.string().uuid(),
  reporterName: z.string().nullable(),
  priority: z.string(),
  issueType: z.string().nullable(),
  dueDate: z.string().nullable(),
  milestoneId: z.string().uuid().nullable(),
  milestoneName: z.string().nullable(),
  labels: z.array(z.string()),
  customFields: z.record(z.string(), z.unknown()),
  parentId: z.string().uuid().nullable(),
  subtaskIds: z.array(z.string().uuid()),
  createdAt: z.string(),
  updatedAt: z.string(),
  workflow: z
    .object({
      key: z.string(),
      name: z.string(),
      repoId: z.string().uuid().nullable(),
      path: z.string().nullable(),
      currentStateLabel: z.string(),
      currentStateCategory: z.string().nullable(),
      currentStateType: z.enum(['initial', 'active', 'final']).nullable(),
    })
    .nullable(),
  sla: z
    .object({
      enteredAt: z.string(),
      elapsedMs: z.number(),
      warnAtMs: z.number().nullable(),
      breachAtMs: z.number().nullable(),
      warning: z.boolean(),
      breached: z.boolean(),
    })
    .nullable(),
});

export const issueListSchema = z.object({
  data: z.array(issueSchema),
});

export const transitionResultSchema = z.object({
  issue: issueSchema,
  from: z.string(),
  to: z.string(),
  intents: z.array(z.unknown()),
  blockers: z.array(z.object({ type: z.string(), message: z.string() })).optional(),
});

export const issueTypeSchema = z.object({
  key: z.string(),
  label: z.string(),
  allowChildren: z.boolean(),
  parentTypes: z.array(z.string()).optional(),
  color: z.string().nullable(),
  icon: z.string().nullable(),
  position: z.number().optional(),
  active: z.boolean(),
  fields: z
    .array(
      z.object({
        key: z.string(),
        label: z.string().optional(),
        type: z.string(),
        options: z.array(z.string()).optional(),
        required: z.boolean().optional(),
      }),
    )
    .optional(),
});

export const issueTypeListSchema = z.object({
  data: z.array(issueTypeSchema),
});

export const milestoneSchema = z.object({
  id: z.string().uuid(),
  organizationId: z.string().uuid(),
  projectId: z.string().uuid(),
  title: z.string(),
  description: z.string().nullable(),
  dueDate: z.string().nullable(),
  status: z.enum(['open', 'closed']),
  createdAt: z.string(),
  updatedAt: z.string(),
});

export const milestoneListSchema = z.object({
  data: z.array(milestoneSchema),
});

export const commentSchema = z.object({
  id: z.string().uuid(),
  issueId: z.string().uuid(),
  authorId: z.string().uuid(),
  authorName: z.string().optional(),
  parentId: z.string().uuid().nullable().optional(),
  body: z.string(),
  replyCount: z.number().int().optional(),
  createdAt: z.string(),
  updatedAt: z.string(),
});

export const commentListSchema = z.object({
  data: z.array(commentSchema),
});

export const workflowSchema = z.object({
  id: z.string(),
  repoId: z.string(),
  organizationId: z.string(),
  projectId: z.string().nullable(),
  key: z.string(),
  workflowKey: z.string(),
  name: z.string(),
  description: z.string().nullable(),
  version: z.number(),
  path: z.string(),
  states: z.array(
    z.object({
      name: z.string(),
      type: z.enum(['initial', 'active', 'final']),
      category: z.string().optional(),
      metadata: z.record(z.string(), z.unknown()).optional(),
    }),
  ),
  transitions: z.array(
    z.object({
      name: z.string().optional(),
      from: z.string(),
      to: z.string(),
    }),
  ),
  definition: z.record(z.string(), z.unknown()),
});

export const workflowListSchema = z.object({
  data: z.array(workflowSchema),
});

export const workflowValidationSchema = z.object({
  valid: z.boolean(),
  errors: z.array(z.string()),
  definition: z.record(z.string(), z.unknown()).optional(),
});

export type CurrentUser = z.infer<typeof currentUserSchema>;
export type Organization = z.infer<typeof organizationSchema>;
export type Project = z.infer<typeof projectSchema>;
export type Issue = z.infer<typeof issueSchema>;
export type IssueType = z.infer<typeof issueTypeSchema>;
export type Milestone = z.infer<typeof milestoneSchema>;
export type Comment = z.infer<typeof commentSchema>;
export type Workflow = z.infer<typeof workflowSchema>;
